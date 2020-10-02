@testset "syntax error reports" begin
    let
        s = """
        begin
            c = rand(Bool)
        end

        end
        """

        res, interp = profile_toplevel(s)

        @test !isempty(res.toplevel_error_reports)
        @test first(res.toplevel_error_reports) isa SyntaxErrorReport
    end
end

@testset "virtual module self-reference" begin
    let
        res, interp = @profile_toplevel begin
            Main.sum("julia") # `Main.sum` should be resolved as constant
        end
        test_sum_over_string(res)
    end
end

@testset "hastopleveldef" begin
    @test hastopleveldef(:(struct Foo end))
    @test hastopleveldef(:(mutable struct Foo end))
    @test hastopleveldef(:(abstract type Foo end))
    @test hastopleveldef(:(primitive type Foo 8 end))
    @test hastopleveldef(:(macro foo(ex); ex; end))
    @test hastopleveldef(:(foo(x) = x))
    @test hastopleveldef(:(foo(x::Foo) where Foo = x))
    @test hastopleveldef(:(function foo(x); return x; end))
    @test hastopleveldef(:(function foo(x::Foo) where Foo; return x; end))
    # just a call
    @test !hastopleveldef(:(foo(x::Foo)))
    # closures
    @test !hastopleveldef(:(let; foo(x) = x; end))
    @test !hastopleveldef(:(foo(bar, function (baz); return isnothing(baz); end)))
    @test !hastopleveldef(:(foo(bar, ()->isnothing(bar))))
    # # toplevel definitions with `Core.eval`
    # @test hastopleveldef(:(for i in 1:10
    #     sym = Symbol(:foo, i)
    #     Core.eval(@__MODULE__, :($(sym)() = $(i)))
    # end))
end

@testset "\"toplevel definitions\"" begin
    let
        vmod = gen_virtualmod()
        @profile_toplevel vmod begin
            # function
            foo() = nothing

            # local function, shouldn't be evaluated
            let
                c = rand(Bool)
                foo′(a) = a || c
            end

            # macro
            macro foo(ex) ex end

            # abstract type
            abstract type Foo end

            # struct
            struct Foo1 <: Foo
                val::Int
            end
            mutable struct Foo2 <: Foo
                val::Int
            end

            # primitive type
            primitive type Foo3 32 end

            # import, using
            using Base: Fix1
            import Base: getproperty

            function getproperty(foo::Foo, sym::Symbol)
                return if sym === :val
                    getfield(foo, sym)::Int
                else
                    getfield(foo, sym)
                end
            end
        end

        @test isdefined(vmod, :foo)
        @test !isdefined(vmod, :foo′)
        @test isdefined(vmod, Symbol("@foo"))
        @test isdefined(vmod, :Foo)
        @test isdefined(vmod, :Foo1)
        @test isdefined(vmod, :Foo2)
        @test isdefined(vmod, :Foo3)
        @test isdefined(vmod, :Fix1)
        @test !isempty(methodswith(getfield(vmod, :Foo), getproperty))
    end

    # "toplevel definitions" with access to global objects
    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            foo = rand(Bool)

            struct Foo
                b::Bool
                Foo(b = foo) = new(b)
            end

            Foo()
        end

        # global variables aren't evaluated but kept in `interp` instead
        @test get_virtual_globalvar(vmod, :foo) isa VirtualGlobalVariable
        @test isdefined(vmod, :Foo)
        @test isempty(res.toplevel_error_reports)
        @test isempty(res.inference_error_reports)
    end
end

@testset "macro expansions" begin
    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            @inline foo(a) = identity(a)
            foo(10)
        end

        @test isdefined(vmod, :foo)
        @test isempty(res.toplevel_error_reports)
        @test isempty(res.inference_error_reports)
    end

    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            macro foo(ex)
                @assert Meta.isexpr(ex, :call)
                push!(ex.args, 1)
                return ex
            end

            @foo sin() # otherwise NoMethodError
        end

        @test isdefined(vmod, Symbol("@foo"))
        @test isempty(res.toplevel_error_reports)
        @test isempty(res.inference_error_reports)
    end

    # macro expansions with access to global variables will fail
    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            const arg = rand(Bool)

            macro foo(ex)
                @assert Meta.isexpr(ex, :call)
                arg && push!(ex.args, 1)
                return ex
            end

            @foo sin()
        end

        @test isdefined(vmod, Symbol("@foo"))
        @test_broken isempty(res.toplevel_error_reports)
        @test isempty(res.inference_error_reports)
    end
end

@testset "remove `const`" begin
    let
        res, interp = @profile_toplevel begin
            const s = "julia"
            sum(s)
        end

        @test isempty(res.toplevel_error_reports)
        test_sum_over_string(res)
    end

    let
        res, interp = @profile_toplevel begin
            let
                const s = "julia"
                sum(s)
            end
        end

        @test !isempty(res.toplevel_error_reports)
        @test first(res.toplevel_error_reports) isa SyntaxErrorReport
    end
end

@testset "expression flattening" begin
    let
        @test (begin
            # internal error shouldn't occur
            res, interp = @profile_toplevel begin
                r = rand(); s = sin(a); c = cos(b); tan(c)
            end
        end; true)
    end
end

@testset "handle `include`" begin
    let
        f1 = normpath(FIXTURE_DIR, "include1.jl")
        f2 = normpath(FIXTURE_DIR, "include1.jl")

        vmod = gen_virtualmod()
        res, interp = profile_file′(f1, vmod)

        @test f1 in res.included_files
        @test f2 in res.included_files
        @test isdefined(vmod, :foo)
        @test isempty(res.toplevel_error_reports)
        @test isempty(res.inference_error_reports)
    end

    let
        f = normpath(FIXTURE_DIR, "nonexistinclude.jl")
        res, interp = profile_file′(f)

        @test f in res.included_files
        @test !isempty(res.toplevel_error_reports)
        @test first(res.toplevel_error_reports) isa ActualErrorWrapped
        @test !isempty(res.inference_error_reports)
        @test first(res.inference_error_reports) isa GlobalUndefVarErrorReport
    end

    let
        f = normpath(FIXTURE_DIR, "selfrecursiveinclude.jl")
        res, interp = profile_file′(f)

        @test f in res.included_files
        @test !isempty(res.toplevel_error_reports)
        @test first(res.toplevel_error_reports) isa RecursiveIncludeErrorReport
    end

    let
        f1 = normpath(FIXTURE_DIR, "chainrecursiveinclude1.jl")
        f2 = normpath(FIXTURE_DIR, "chainrecursiveinclude2.jl")
        res, interp = profile_file′(f1)

        @test f1 in res.included_files
        @test f2 in res.included_files
        @test !isempty(res.toplevel_error_reports)
        let
            report = first(res.toplevel_error_reports)
            @test report isa RecursiveIncludeErrorReport
            @test report.duplicated_file == f1
            @test f1 in report.files
            @test f2 in report.files
            @test report.file == f2
            @test report.line == 1
        end
    end
end

@testset "module definition" for s in ("""
                                       module foo end
                                       """,
                                       """
                                       baremodule foo end
                                       """,
                                       """
                                       module foo
                                       module bar end
                                       end
                                       """
                                       )
    res, interp = profile_toplevel(s)
    @test isempty(res.toplevel_error_reports)
end

@testset "module usage" begin
    # using
    let
        res, interp = @profile_toplevel begin
            module foo

            using Base.Meta: isexpr

            isexpr(:(foo(bar)), :call)
            isexpr2(:(foo(bar)), :call)

            end
        end

        @test isempty(res.toplevel_error_reports)
        @test !isempty(res.inference_error_reports)
        @test first(res.inference_error_reports) isa GlobalUndefVarErrorReport
        @test occursin("isexpr2", first(res.inference_error_reports).msg)
    end

    # sequential usage
    let
        res, interp = @profile_toplevel begin
            module foo

            bar(s) = sum(s)

            module baz

            using ..foo

            bar("julia") # -> GlobalUndefVarErrorReport

            end # module bar

            end # module foo
        end

        @test isempty(res.toplevel_error_reports)
        @test !isempty(res.inference_error_reports)
        @test first(res.inference_error_reports) isa GlobalUndefVarErrorReport
    end

    # usage of global objects
    let
        res, interp = @profile_toplevel begin
            module foo

            bar(s) = sum(s)

            module baz

            using ..foo

            foo.bar("julia") # -> NoMethodErrorReports

            end # module bar

            end # module foo
        end

        @test isempty(res.toplevel_error_reports)
        test_sum_over_string(res)
    end

    let
        res, interp = @profile_toplevel begin
            module foo

            bar(s) = sum(s)

            module baz

            using ..foo: bar

            bar("julia") # -> NoMethodErrorReports

            end # module bar

            end # module foo
        end

        @test isempty(res.toplevel_error_reports)
        test_sum_over_string(res)
    end

    @testset "module usage of virtual global variable" begin
        let
            res, interp = @profile_toplevel begin
                module foo

                const bar = sum

                module baz

                using ..foo: bar

                bar("julia")

                end # module bar

                end # module foo
            end

            @test isempty(res.toplevel_error_reports)
            test_sum_over_string(res)
        end

        let
            res, interp = @profile_toplevel begin
                module foo

                const bar = "julia"

                module baz

                using ..foo: bar

                sum(bar)

                end # module bar

                end # module foo
            end

            @test isempty(res.toplevel_error_reports)
            test_sum_over_string(res)
        end

        let
            res, interp = @profile_toplevel begin
                module foo

                const bar = "julia"

                export bar

                end # module foo

                using .foo
                sum(bar)
            end

            @test isempty(res.toplevel_error_reports)
            test_sum_over_string(res)
        end
    end

    # export
    let
        res, interp = @profile_toplevel begin
            module foo

            bar(s) = sum(s)

            export bar

            end

            using .foo

            bar("julia") # -> NoMethodErrorReports
        end

        @test isempty(res.toplevel_error_reports)
        test_sum_over_string(res)
    end
end

@testset "sequential" begin
    let
        res, interp = @profile_toplevel begin
            foo(1:1000)

            foo(a) = length(a)
        end
        @test length(res.inference_error_reports) === 1
        @test first(res.inference_error_reports) isa GlobalUndefVarErrorReport
    end

    let
        res, interp = @profile_toplevel begin
            foo(a) = length(a)
            foo("julia") # should not error

            foo(a) = sum(a)
            foo(1:1000)  # should not error too
        end
        @test isempty(res.inference_error_reports)
    end
end

@testset "virtual global variables" begin
    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            var = rand(Bool)
            const constvar = rand(Bool)
        end

        var = get_virtual_globalvar(vmod, :var)
        @test var isa VirtualGlobalVariable && var.t ⊑ Bool

        constvar = get_virtual_globalvar(vmod, :constvar)
        @test constvar isa VirtualGlobalVariable && constvar.t ⊑ Bool
    end

    @testset "scope" begin
        # function
        # --------

        let
            vmod = gen_virtualmod()
            interp, frame = Core.eval(vmod, :($(profile_call)() do
                local localvar = rand(Bool)
                global globalvar = rand(Bool)
            end))

            @test isnothing(get_virtual_globalvar(vmod, :localvar))

            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        # blocks
        # ------

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                begin
                    globalvar = rand(Bool)
                end
            end

            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                begin
                    local localvar = rand(Bool)
                    globalvar = localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                begin
                    local localvar
                    localvar = rand(Bool) # this shouldn't be annotated as `global`
                    globalvar = localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                globalvar2 = begin
                    local localvar = rand(Bool)
                    globalvar1 = localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :locbalvar))
            globalvar1 = get_virtual_globalvar(vmod, :globalvar1)
            @test globalvar1 isa VirtualGlobalVariable && globalvar1.t ⊑ Bool
            globalvar2 = get_virtual_globalvar(vmod, :globalvar2)
            @test globalvar2 isa VirtualGlobalVariable && globalvar2.t ⊑ Bool
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                let
                    localvar = rand(Bool)
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                globalvar = let
                    localvar = rand(Bool)
                    localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        # loops
        # -----

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                for i = 1:100
                    localvar = i
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                for i in 1:10
                    localvar = rand(Bool)
                    global globalvar = localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                while true
                    localvar = rand(Bool)
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                while true
                    localvar = rand(Bool)
                    global globalvar = localvar
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :localvar))
            globalvar = get_virtual_globalvar(vmod, :globalvar)
            @test globalvar isa VirtualGlobalVariable && globalvar.t ⊑ Bool
        end
    end

    @testset "multiple declaration/assignment" begin
        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                s, c = sincos(1)
            end

            s = get_virtual_globalvar(vmod, :s)
            @test s isa VirtualGlobalVariable && s.t ⊑ Float64
            c = get_virtual_globalvar(vmod, :c)
            @test c isa VirtualGlobalVariable && c.t ⊑ Float64
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                begin
                    local s, c
                    s, c = sincos(1)
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :s))
            @test isnothing(get_virtual_globalvar(vmod, :c))
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                let
                    global s, c
                    s, c = sincos(1)
                end
            end

            s = get_virtual_globalvar(vmod, :s)
            @test s isa VirtualGlobalVariable && s.t ⊑ Float64
            c = get_virtual_globalvar(vmod, :c)
            @test c isa VirtualGlobalVariable && c.t ⊑ Float64
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                so, co = let
                    si, ci = sincos(1)
                    si, ci
                end
            end

            @test isnothing(get_virtual_globalvar(vmod, :si))
            @test isnothing(get_virtual_globalvar(vmod, :ci))
            so = get_virtual_globalvar(vmod, :so)
            @test so isa VirtualGlobalVariable && so.t ⊑ Float64
            co = get_virtual_globalvar(vmod, :co)
            @test co isa VirtualGlobalVariable && co.t ⊑ Float64
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                begin
                    local l
                    l, g = sincos(1)
                end
            end
            @test isnothing(get_virtual_globalvar(vmod, :l))
            @test_broken !isnothing(get_virtual_globalvar(vmod, :g))
        end
    end
end
