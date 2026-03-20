module Repology

using TOML: TOML

const REPOSITORY_DATA = Ref{Dict{String,String}}()
function repository_data()
    isassigned(REPOSITORY_DATA) && return REPOSITORY_DATA[]
    data = TOML.parsefile(joinpath(@__DIR__, "..", "data", "repositories.toml"))
    for (k,v) in data
        # also store normalized URLs directly for matching
        data[normalize_url(k)] = v
    end
    return REPOSITORY_DATA[] = data
end
const DOWNLOAD_DATA = Ref{Dict{String,Tuple{String,String}}}()
function download_data()
    isassigned(DOWNLOAD_DATA) && return DOWNLOAD_DATA[]
    data = Dict{String,Tuple{String,String}}()
    for (k,v) in TOML.parsefile(joinpath(@__DIR__, "..", "data", "downloads.toml"))
        data[k] = (v[1], v[2])
        data[normalize_url(k)] = (v[1], v[2])
    end
    return DOWNLOAD_DATA[] = data
end
const DOWNLOAD_PREFIX_POSTFIX_MAP = Ref{Dict{String,Vector{Pair{String,String}}}}()
const MAX_PREFIX_LENGTH = 120
function download_prefix_postfix_map()
    isassigned(DOWNLOAD_PREFIX_POSTFIX_MAP) && return DOWNLOAD_PREFIX_POSTFIX_MAP[]
    map = Dict{String,Vector{Pair{String,String}}}()
    for (k,v) in download_data()
        version = chopprefix(v[2], "v") # drop an optional v prefix
        length(version) >= 3 || continue # ensure non-trivial version numbers
        version[1] in '0':'9' || continue # ensure version starts with a digit
        matches = split(k, version)
        length(matches) == 2 || continue # ensure version is only referenced once
        prefix, postfix = matches
        length(prefix) > MAX_PREFIX_LENGTH && continue # skip absurdly long prefixes
        sort!(unique!(push!(get!(map, prefix, Pair{String,String}[]), postfix=>v[1])), by=length∘first, rev=true)
    end
    return DOWNLOAD_PREFIX_POSTFIX_MAP[] = map
end

const CPE_DATA = Ref{Dict{String,Any}}()
function cpe_data()
    isassigned(CPE_DATA) && return CPE_DATA[]
    return CPE_DATA[] = TOML.parsefile(joinpath(@__DIR__, "..", "data", "cpes.toml"))
end

"""
    normalize_url(url)

Given a URL, strip the scheme (e.g., https:// or git://) and known/common extension suffixes
"""
function normalize_url(url)
    # TODO: it'd be nice to also support Gentoo/Pacman mirror:// style URLs and known mirrors
    url = chopprefix(url, r"^[^:]+://(www\.|ftp\.)?")
    url = chopsuffix(url, r"(\.tar)?\.(gz|bz2|xz|zip|bzip2|tgz|tbz2|git)$")
    return url
end

const _GIT_CACHE = Dict{String,String}()
function get_version_from_commit(repo, commit; git_cache=_GIT_CACHE, include_parent=true)
    try
        dir = get!(git_cache, repo) do
            tmp = mktempdir()
            run(pipeline(`git clone --filter=tree:0 --no-checkout --tags $repo $tmp`, stdout=Base.devnull, stderr=Base.devnull))
            tmp
        end
        tag = cd(dir) do
            buf = IOBuffer()
            for c in (include_parent ? (commit, commit*"~") : (commit,))
                if success(pipeline(`git tag --points-at $c`, stdout=buf, stderr=Base.devnull)) && position(buf) > 0
                    return String(take!(buf))
                end
                seekstart!(buf)
                if success(pipeline(`git fetch origin $c`, stdout=Base.devnull, stderr=Base.devnull)) &&
                    success(pipeline(`git tag --points-at $c`, stdout=buf, stderr=Base.devnull)) && position(buf) > 0
                    return String(take!(buf))
                end
                seekstart!(buf)
            end
            return ""
        end
        # It can be challenging to parse a version number out of a tag; some options here include: v1.2.3 and PCRE2-1.2.3
        # This strips all non-numeric prefixes with up to one digit as long as the digit is not followed by a period.
        # and ignore everything after a newline (multiple tags are newline separated, with the latest first)
        ver = strip(split(chopprefix(tag, r"^[^\d]*(?:\d[^\d.]+)?"), "\n", limit=2)[1])
        return isempty(ver) ? nothing : ver
    catch _
        return nothing
    end
end

"""
    (project, version) = identify_upstream(url, hash)

Given a URL and a hash, attempt to identify the upstream project and version using data from Repology.

If no project is found, returns `(nothing, nothing)`, and it may return `(proj, nothing)` if no version info is available

Note that for repositories, it will attempt to download the git repository for versioning/tag information.
"""
function identify_upstream(url, hash)
    # First look for this URL in downloads; those are only populated if the version
    # number is in the URL, so it's highly unlikely to be a false-positive and actually
    # be a repository URL if it matches a known download.
    dls = download_data()
    repos = repository_data()
    # First look for exact or normalized matches directly
    for u in (url, normalize_url(url))
        haskey(dls, u) && return dls[u]
        haskey(repos, u) && return (repos[u], get_version_from_commit(url, hash))
    end

    # Finally, we can look for download URLs with a similar version pattern as a known URL.
    # this is surprisingly expensive as there are a lot of patterns, so we use a map of
    # prefix and postfix patterns to find the longest one that matches and then ensure
    # we got something version-ish back
    for u in (url, normalize_url(url))
        idx = min(MAX_PREFIX_LENGTH, prevind(u, lastindex(u), 2))
        while idx > 5
            idx = prevind(u, idx)
            prefix = SubString(u, 1, idx)
            for (postfix, proj) in get(download_prefix_postfix_map(), prefix, Pair{String,String}[])
                if endswith(url, postfix)
                    ver = chopprefix(chopsuffix(u, postfix), prefix)
                    if length(ver) >= 3 && ver[1] in '0':'9' && !contains(ver, "/")
                        return (proj, ver)
                    end
                end
            end
        end
    end

    return (nothing, nothing)
end

end
