module Repology

using TOML: TOML
using DataStructures: OrderedDict

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
const DOWNLOAD_PREFIX_REGEX_MAP = Ref{Dict{String,Vector{Pair{Regex,String}}}}()
const MAX_PREFIX_LENGTH = 120
function download_prefix_regex_map()
    isassigned(DOWNLOAD_PREFIX_REGEX_MAP) && return DOWNLOAD_PREFIX_REGEX_MAP[]
    map = Dict{String,OrderedDict{String,String}}()
    for (k,v) in download_data()
        version = chopprefix(v[2], "v") # drop an optional v prefix
        length(version) >= 3 || continue # ensure non-trivial version numbers
        version[1] in '0':'9' || continue # ensure version starts with a digit

        # There are three very common cases:
        # * The version number appears exactly once or more
        # * The version number appears once and a _subset_ (often just major/minor) or _munged_ flavor of it appears a second time
        #   - these often appear _before_ the real version number
        idx = findfirst(version, k)
        idx === nothing && continue # ensure the version number appears in the URL at least once
        prefix, rest = SubString(k, 1, prevind(k, idx[1])), SubString(k, idx[1])
        length(prefix) > MAX_PREFIX_LENGTH && continue # skip absurdly long prefixes

        # Now we transform rest into a regular expression to match the version number one or more times
        vpat = replace(replace(rest, version => "\\E(.*?)\\Q"; count=1), version => "\\E\\1\\Q")
        pattern = string("^\\Q", vpat, "\\E\$")

        suffix_map = get!(map, prefix, OrderedDict{String,String}())
        if haskey(suffix_map, pattern) && suffix_map[pattern] != v[1]
            # If we have multiple projects with the same prefix/regex pair, we can't use it for matching
            # These are often just bad aliases in the data
            suffix_map[pattern] = ""
        else
            suffix_map[pattern] = v[1]
        end

        # Now, secondarily, if a non-trivial prefix of the version number appears in the prefix, we also support that.
        munged_version = version
        while (munged_version = munged_version[1:prevind(munged_version, end)]; length(munged_version) >= 3)
            if contains(prefix, munged_version)
                idx = findfirst(munged_version, k)
                prefix, rest = SubString(k, 1, prevind(k, idx[1])), SubString(k, idx[1])
                vpat = replace(replace(rest, version => "\\E(.*?)\\Q"; count=1), version => "\\E\\1\\Q")
                vpat = replace(vpat, munged_version => "\\E.{$(length(munged_version))}\\Q") # just do a fixed-width wildcard
                pattern = string("^\\Q", vpat, "\\E\$")

                suffix_map = get!(map, prefix, OrderedDict{String,String}())
                if haskey(suffix_map, pattern) && suffix_map[pattern] != v[1]
                    # If we have multiple projects with the same prefix/regex pair, we can't use it for matching
                    # These are often just bad aliases in the data
                    suffix_map[pattern] = ""
                else
                    suffix_map[pattern] = v[1]
                end
                break
            end
        end
    end
    for (_,suffixmap) in map
        # Now remove the "" sentinels we set for ambiguous cases
        filter!(((k,v),)->v != "", suffixmap)
        # And sort the suffixes by length so we always match the longest one first
        sort!(suffixmap, by=length, rev=true)
    end
    # And, finally, compile all the regexes, preserving their ordering for longest (plaintext) match first
    return DOWNLOAD_PREFIX_REGEX_MAP[] = Dict{String, Vector{Pair{Regex,String}}}(k => Pair{Regex,String}[(Regex(p) => v) for (p,v) in suffixmap] for (k,suffixmap) in map)
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
    # TODO: it'd be nice to also support normalizing Gentoo/Pacman mirror:// style URLs and known mirrors
    return lowercase(url) |>
        x->chopprefix(x, r"^[^:]+://(www\.|ftp\.)?") |>
        x->chopsuffix(x, r"(?:\.tar)?\.(?:gz|bz2|xz|zip|bzip2|tgz|tbz2|git)(?:/download)?$") |>
        x->replace(x, r"//+" => "/")
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
    # prefix and regex patterns to find the longest one that matches and then ensure
    # we got something version-ish back
    prefix_regex_map = download_prefix_regex_map()
    for u in (url, normalize_url(url))
        idx = min(MAX_PREFIX_LENGTH, prevind(u, lastindex(u), 2))
        while idx > 5
            idx = prevind(u, idx)
            prefix = SubString(u, 1, idx)
            rest = SubString(u, nextind(u, idx))
            for (regex, proj) in get(prefix_regex_map, prefix, Pair{Regex,String}[])
                m = match(regex, rest)
                isnothing(m) && continue
                ver = m.captures[1]
                if length(ver) >= 3 && ver[1] in '0':'9' && !contains(ver, "/")
                    return (proj, ver)
                end
            end
        end
    end

    return (nothing, nothing)
end

end
