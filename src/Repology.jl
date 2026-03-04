module Repology

"""
    normalize_repo(url)

Given a URL to some repository, strip the schema (e.g., https:// or git://) and .git suffix (if they exist)
"""
normalize_repo(url) = chopprefix(chopsuffix(url, ".git"), r"[^:/]+://")

function get_version_from_commit(repo, commit; git_cache=Dict{String,String}())
    try
        dir = get!(git_cache, repo) do
            tmp = mktempdir()
            run(pipeline(`git clone --filter=tree:0 --no-checkout --tags $repo $tmp`, stdout=Base.devnull, stderr=Base.devnull))
            tmp
        end
        tag = cd(dir) do
            try
                readchomp(`git tag --points-at $commit`)
            catch _
                try
                    run(`git fetch origin $commit`)
                    readchomp(`git tag --points-at $commit`)
                catch _
                    ""
                end
            end
        end
        # It can be challenging to parse a version number out of a tag; some options here include: v1.2.3 and PCRE2-1.2.3
        # This strips all non-numeric prefixes with up to one digit as long as the digit is not followed by a period.
        # and ignore everything after a newline (multiple tags are newline separated, with the latest first)
        ver = strip(split(chopprefix(tag, r"^[^\d]*(?:\d[^\d.]+)?"), "\n", limit=2)[1])
        return ver
    catch ex
        @warn "Failed to clone repo $repo to get version information for commit $commit" ex
        return ""
    end
end

function merge_components!(dest, src)
    for (upstream_project, upstream_versions) in src
        if haskey(dest, upstream_project)
            union!(dest[upstream_project], upstream_versions)
        else
            dest[upstream_project] = upstream_versions
        end
    end
    return dest
end

function identify_components(source; repositories, url_patterns, git_cache=Dict{String,String}())
    component_info = Dict{String, Vector{String}}()
    if haskey(source, "url")
        for (upstream_project, upstream_version) in all_matches(url_patterns, source["url"])
            v = isempty(upstream_version) ? ["*"] : [upstream_version]
            haskey(component_info, upstream_project) ?
                union!(component_info[upstream_project], v) :
                component_info[upstream_project] = v
        end
    end
    if haskey(source, "repo") && haskey(source, "hash") && haskey(repositories, normalize_repo(source["repo"]))
        upstream_project = repositories[normalize_repo(source["repo"])]
        commit = source["hash"]
        # Now the hard part are versions...
        ver = get_version_from_commit(source["repo"], commit; git_cache)
        if isempty(ver)
            # try getting it from the prior version
            # lots of projects tag and then make some minor version number fix
            ver = get_version_from_commit(source["repo"], commit*"~"; git_cache)
            !isempty(ver) && @info "$upstream_project: found tag at $commit~"
        end
        if !isempty(ver)
            @info "$upstream_project: got version $(ver) from git repo tag"
            haskey(component_info, upstream_project) ?
                union!(component_info[upstream_project], [ver]) :
                component_info[upstream_project] = [ver]
        else
            @info "$upstream_project: failed to get tag from repo $(source["repo"])"
            component_info[upstream_project] = ["*"]
        end
    end
    return component_info
end

function all_matches(pattern_project_pairs, needle)
    result = Tuple{String,String}[]
    for (pattern, project) in pattern_project_pairs
        m = match(pattern, needle)
        !isnothing(m) && push!(result, (project, m.captures[1]))
    end
    return result
end


end
