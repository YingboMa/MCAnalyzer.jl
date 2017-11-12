__precompile__(true)
module IACA
export iaca_start, iaca_end, analyze

using LLVM
import Compat: @nospecialize

const jlctx = Ref{LLVM.Context}()
const opt_level = Ref{Int}()

function __init__()
    jlctx[] = LLVM.Context(convert(LLVM.API.LLVMContextRef,
                                   cglobal(:jl_LLVMContext, Void)))

    opt_level[] = Base.JLOptions().opt_level
end

"""
    analyze(func, tt, march = :SKL)

Analyze a given function `func` with the type signature `tt`.
The specific method needs to be annotated with the `IACA` markers.
Supported `march` are :HSW, :BDW, :SKL, and :SKX.

# Example

```julia
function mysum(A)
    acc = zero(eltype(A))
    for a in A
        iaca_start()
        acc += a
    end
    iaca_end()
    return acc
end

analyze(mysum, Tuple{Vector{Float64}})
```

# Advanced usage
## Switching opt-level (0.7 only)
```julia
IACA.opt_level[] = 3
analyze(mysum, Tuple{Vector{Float64}}, :SKL, #=default_op=# false)
````

## Changing the optimization pipeline

```julia
myoptimize!(tm, mod) = ...
analyze(mysum. Tuple{Vector{Float64}}, :SKL, #=default_op=# false, #=optimize!=# myoptimize!)
````
"""
function analyze(@nospecialize(func), @nospecialize(tt), march=:SKL, default_opt = true, optimize! = jloptimize!)
    iaca_path = "iaca"
    if haskey(ENV, "IACA_PATH")
        iaca_path = ENV["IACA_PATH"]
    end
    @assert !isempty(iaca_path)

    cpus = Dict(
        :HSW => "haswell",
        :BDW => "broadwell",
        :SKL => "skylake",
        :SKX => "skx",
    )
    @assert haskey(cpus, march) "Arch: $march not supported"

    mktempdir() do dir
        objfile = joinpath(dir, "a.out")
        tm, mod, _ = irgen(func, tt, cpus[march], "", default_opt, optimize!)
        LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile, objfile)
        Base.run(`$iaca_path -arch $march $objfile`)
    end
end

nameof(f::Core.Function) = String(typeof(f).name.mt.name)

function irgen(@nospecialize(func), @nospecialize(tt), cpu, features, default_opt, optimize!)
    params = Base.CodegenParams(cached=false)

    mod = parse(LLVM.Module,
                Base._dump_function(func, tt,
                                    #=native=#false, #=wrapper=#false, #=strip=#false,
                                    #=dump_module=#true, #=syntax=#:att, #=optimize=#default_opt, params), jlctx[])

    fn = nameof(func)
    julia_fs = Dict{String,Dict{String,LLVM.Function}}()
    r = r"^(?P<cc>(jl|japi|jsys|julia)[^\W_]*)_(?P<name>.+)_\d+$"
    for llvmf in functions(mod)
        m = match(r, LLVM.name(llvmf))
        if m != nothing
            fns = get!(julia_fs, m[:name], Dict{String,LLVM.Function}())
            fns[m[:cc]] = llvmf
        end
    end

    # find the native entry-point function
    haskey(julia_fs, fn) || error("could not find compiled function for $fn")
    entry_fs = julia_fs[fn]
    if !haskey(entry_fs, "julia")
        error("could not find native function for $fn, available CCs are: ",
              join(keys(entry_fs), ", "))
    end
    llvmf = entry_fs["julia"]

    triple = LLVM.triple(mod)
    target = LLVM.Target(triple)
    tm = LLVM.TargetMachine(target, triple, cpu, features)
    !default_opt && optimize!(tm, mod)

    return tm, mod, llvmf
end

"""
    jloptimize!(tm, mod)

Runs the Julia optimizer pipeline.
"""
function jloptimize!(tm::LLVM.TargetMachine, mod::LLVM.Module)
    ModulePassManager() do pm
        if Base.VERSION >= v"0.7.0-DEV.1494"
            add_library_info!(pm, triple(mod))
            add_transform_info!(pm, tm)
            ccall(:jl_add_optimization_passes, Void,
                  (LLVM.API.LLVMPassManagerRef, Cint),
                  LLVM.ref(pm), opt_level[])
        else
            add_transform_info!(pm, tm)
            # TLI added by PMB
            ccall(:LLVMAddLowerGCFramePass, Void,
                  (LLVM.API.LLVMPassManagerRef,), LLVM.ref(pm))
            ccall(:LLVMAddLowerPTLSPass, Void,
                  (LLVM.API.LLVMPassManagerRef, Cint), LLVM.ref(pm), 0)

            always_inliner!(pm) # TODO: set it as the builder's inliner
            PassManagerBuilder() do pmb
                populate!(pm, pmb)
            end
        end

        run!(pm, mod)
    end
end

function gen_iaca(code, name)
    mod = LLVM.Module("IACA", jlctx[])
    ft = LLVM.FunctionType(LLVM.VoidType(jlctx[]))
    # ATT syntax target comes last
    raw_asm = """
        movl \$\$$code, %ebx
        .byte 0x64, 0x67, 0x90
        """
    # defined in iacaMarks.h as volatile with a memory clobber
    # dirflag, fpsr, flags are taken from clang
    asm = InlineAsm(ft, raw_asm, #=constraints=# "~{memory},~{dirflag},~{fpsr},~{flags}", #=side-effects=# true )
    llvmf = LLVM.Function(mod, "iaca_$name", ft)

    Builder(jlctx[]) do builder
        entry = BasicBlock(llvmf, "entry", jlctx[])
        position!(builder, entry)

        # insert call to asm
        call!(builder, asm)
        ret!(builder)
    end
    push!(function_attributes(llvmf), EnumAttribute("alwaysinline"))

    return llvmf
end

"""
    iaca_start()

Insertes IACA start marker at this position.
"""
@generated function iaca_start()
    llvmf = gen_iaca("111", "start")
    quote
        Base.@_inline_meta
        Base.llvmcall(LLVM.ref($llvmf), Void, Tuple{})
        return nothing
    end
end

"""
    iaca_end()

Insertes IACA end marker at this position.
"""
@generated function iaca_end()
    llvmf = gen_iaca("222", "end")
    quote
        Base.@_inline_meta
        Base.llvmcall(LLVM.ref($llvmf), Void, Tuple{})
        return nothing
    end
end

end # module
