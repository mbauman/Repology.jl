using TOML: TOML
using DataStructures: DefaultDict, DefaultOrderedDict, OrderedDict
using CSV: CSV
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, combine, eachrow

function import_dump()
    run(pipeline(`curl -s https://dumps.repology.org/repology-database-dump-latest.sql.zst`,
        `zstd -d`,
        `psql -v ON_ERROR_STOP=1`))
end

function gather_links()
    @info "gather repositories from package downloads"
    sql = """
        COPY (SELECT
            (elem.value ->> 0)::integer AS link_type,
            l.url,
            p.repo,
            p.effname,
            p.rawversion,
            p.arch,
            p.origversion,
            p.versionclass
        FROM packages p
        CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
        JOIN links l ON l.id = (elem.value ->> 1)::integer
        WHERE ((elem.value ->> 0)::integer = 1 or (elem.value ->> 0)::integer = 2))
        TO STDOUT WITH (format csv);
    """
    df = mktemp() do _, io
        run(pipeline(`psql -U repology -c $sql`, stdout=io))
        seekstart(io)
        CSV.read(io, DataFrame, header=["link_type",
            "url",
            "repo",
            "effname",
            "arch",
            "rawversion",
            "origversion",
            "versionclass"])
    end
    # We'll only trust download URLs when only one was used for the given package
    # Many packages have more than one download, but then we don't know if that was a (build) dependency
    # or the actual project or perhaps some larger meta-project that vendors lots of deps.
    filtered_df = df |>
        x -> groupby(x, [:repo, :effname, :rawversion, :arch]) |>
        x -> transform(x, :url => (x -> length(unique(x))) => :n_unique_urls) |>
        x -> filter(row -> row.n_unique_urls == 1, x) |>
        # And also remove any rows for which the same URL points at two different effnames:
        x -> groupby(x, :url) |>
        x -> transform(x, :effname => (x -> length(unique(x))) => :n_unique_effnames) |>
        x -> filter(row -> row.n_unique_effnames == 1, x)

    # For repositories (link_type == 2), ignore versions
    repositories = Dict{String,String}()
    for row in eachrow(filtered_df[filtered_df.link_type .== 2, :])
        if haskey(repositories, row.url) && repositories[row.url] != row.effname
            @warn "$(row.url) identifies both $(row.effname) and $(repositories[row.url])"
            repositories[row.url] = "" # poison repos that are used for more than one project
            continue
        end
        repositories[row.url] = row.effname
    end
    filter!(!isempty∘last, repositories)

    @info "gather downloads"
    # For downloads (link_type == 1), the versions may be meaningfully linked to the URL
    url_groups = combine(groupby(filtered_df[filtered_df.link_type .== 1, :], [:url, :effname]), :origversion => (x -> [unique(x)]) => :versions)
    downloads = Dict{String, Pair{String,String}}()
    for row in eachrow(url_groups)
        length(row.versions) == 1 || continue
        # Ignore download URLs that don't explicitly include the URL
        # these are often things like -latest or the like
        v = only(row.versions)
        contains(row.url, v) || continue
        if haskey(downloads, row.url) && downloads[row.url] != (row.effname => v)
            @warn "$(row.url) identifies both $(row.effname => v) and $(downloads[row.url])"
            downloads[row.url] = "" => ""
            continue
        end
        downloads[row.url] = (row.effname => v)
    end
    filter!(!isempty∘last∘last, downloads)

    return downloads, repositories
end

function gather_cpes()
    @info "gather CPEs"
    sql = """
        COPY (SELECT DISTINCT
            p.effname,
            p.cpe_vendor || ':' || p.cpe_product AS cpe
        FROM packages p
        WHERE p.cpe_vendor IS NOT NULL AND p.cpe_product IS NOT NULL)
        TO STDOUT WITH (format csv);
    """
    df = mktemp() do _, io
        run(pipeline(`psql -U repology -c $sql`, stdout=io))
        seekstart(io)
        CSV.read(io, DataFrame, header=["effname", "cpe"])
    end
    cpes = Dict{String,Vector{String}}()
    for row in eachrow(df)
        push!(get!(cpes, row.effname, String[]), row.cpe)
    end
    # And now override those with manual entries, if they exist:
    sql = """
        COPY (SELECT
            p.effname,
            p.cpe_vendor || ':' || p.cpe_product AS cpe
        FROM manual_cpes p
        WHERE p.cpe_vendor IS NOT NULL AND p.cpe_product IS NOT NULL)
        TO STDOUT WITH (format csv);
    """
    df = mktemp() do _, io
        run(pipeline(`psql -U repology -c $sql`, stdout=io))
        seekstart(io)
        CSV.read(io, DataFrame, header=["effname", "cpe"])
    end
    cpe_overrides = Dict{String,Vector{String}}()
    for row in eachrow(df)
        push!(get!(cpe_overrides, row.effname, String[]), row.cpe)
    end
    merge!(cpes, cpe_overrides)
    return cpes
end

function main()
    if !success(`psql -U repology -c "SELECT * FROM packages LIMIT 1"`)
        @info "building database"
        import_dump()
    end

    downloads, repositories = gather_links()
    cpes = gather_cpes()
   
    data = joinpath(@__DIR__, "..", "data")
    mkpath(data)

    header = "# This file is autogenerated with data from https://repology.com"
    open("$data/repositories.toml", "w") do io
        println(io, header)
        TOML.print(io, repositories, sorted=true)
    end
    open("$data/downloads.toml", "w") do io
        println(io, header)
        TOML.print(io, Dict(k=>[v...] for (k,v) in downloads), sorted=true)
    end
    open("$data/cpes.toml", "w") do io
        println(io, header)
        TOML.print(io, cpes, sorted=true)
    end

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
