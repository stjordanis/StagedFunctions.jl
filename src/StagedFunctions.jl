module StagedFunctions # end

export @staged

@assert VERSION >= v"1.3.0-DEV.379"
# TODO: THIS MUST BE BUILT WITH A MODIFIED VERSION OF JULIA TO EXPORT A NEEDED FUNCTION.
# YOU CAN CHECKOUT AND BUILD FROM THIS BRANCH:
#    https://github.com/NHDaly/julia/tree/export_jl_resolve_globals_in_ir

using Cassette # To share their 265 fixing code
using MacroTools

function expr_to_codeinfo(m, f, t, e)

    scoped = Expr(Symbol("scope-block"),
    Expr(:block,
        Expr(:return,
            Expr(:block,
                e,
            ))))

    # TODO: Is this right? Should we really be using `Type`, not `Type{Int}`?
    #function_sig = (typeof(f), map(Core.Typeof, t)...)
    function_sig = (typeof(f), (Type for _ in t)...)
    reflection = Cassette.reflect(function_sig)
    ci = reflection.code_info
    ge = Expr(:lambda, ci.slotnames, scoped)
    l = Meta.lower(m, ge)
    ci.code = l.code
    # TODO this requires modifications to Julia to expose jl_resolve_globals_in_ir
    ccall(:jl_resolve_globals_in_ir, Cvoid, (Any, Any, Any), ci.code, @__MODULE__,
            Core.svec(reflection.static_params...)
         )
    ci
end

# ---- Utilities -------
"""
    argnames(fsig.args[2:end])

Return an array of names or gensymed names for each argument in an args list:
```julia-repl
julia> argnames(:(f(x::Int, ::Float32, z)).args[2:end])
3-element Array{Any,1}:
 :x
 Symbol("##_1#413")
 :z
```
"""
function argnames(args::Array)
    tmpcount = 0
    out = []
    for a in args
        name = argname(a)
        if name == nothing
            tmpcount += 1
            name = gensym("_$tmpcount")
        end
        push!(out, name)
    end
    out
end
argname(x::Symbol) = (x)
function argname(e::Expr)
    @assert e.head == Symbol("::")  "Expected (x::T), Got $e"
    return length(e.args) == 2 ? (e.args[1]) : nothing
end
# ---------------------

function _make_generator(f)
    global e = f
    signature = f.args[1]
    (fname, fargs) = signature.args[1], signature.args[2:end]

    # Strip type-assertions and gensymed missing names for all args
    # (x::Int, y, ::Float32) -> (x,y,##genarg##)
    signature.args = argnames(signature.args)

    # Update f to be the generatorbody
    generatorbodyname = signature.args[1] = gensym(:generatorbody)
    f_stager = gensym( Symbol("$(fname)_stager") )
    esc(:(
        $f;   # user-written generator body function
        function $f_stager(self, args...)
            # Within this function, args are types.

            # Call the generatorbody at latest world-age, to avoid currently frozen world-age.
            expr = Core._apply_pure($generatorbodyname, (args...,))
            code_info = $(@__MODULE__).expr_to_codeinfo(@__MODULE__, $generatorbodyname, (args...,), expr)

            code_info
        end;
        function $fname($(fargs...))   # staged function
            $(Expr(:meta, :generated_only))
            $(Expr(:meta,
                :generated,
                Expr(:new,
                    Core.GeneratedFunctionStub,
                    f_stager,
                    Any[fname, fargs...],
                    Any[],  # spnames
                    @__LINE__,
                    QuoteNode(Symbol(@__FILE__)),
                    true)))
        end
    ))
end

macro staged(f)
    @assert isa(f, Expr) && (f.head === :function || Base.is_short_function_def(f)) "invalid syntax; @staged must be used with a function definition"

    _make_generator(f)
end

end # module