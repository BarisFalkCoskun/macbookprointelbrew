# frozen_string_literal: true

# Intel (x86_64, macOS 15 Sequoia) bottle builder and client.
#
# The same file runs in two places:
#
#   GitHub Actions runner:  brew ruby scripts/bottler.rb build [formula ...]
#   MacBook (via ibrew):    <Homebrew's portable ruby> bottler.rb install|upgrade|reinstall [formula ...]
#
# The MacBook avoids `brew ruby` because it is a developer command and running
# it switches on Homebrew's developer mode for good (brew update then tracks
# the unreleased main branch). Without Homebrew's libraries, small stand-ins
# below replace PkgVersion and the ohai/opoo output helpers.
#
# Options are env vars named HOMEBREW_*, the only ones `brew ruby` passes through:
#   HOMEBREW_IBREW_REPO              owner/repo holding the "bottles" release (required)
#   HOMEBREW_IBREW_DRY_RUN=1         client: print the plan, change nothing
#   HOMEBREW_IBREW_WAIT_MINUTES      client: how long to wait for remote builds (240)
#   HOMEBREW_IBREW_REF               client: branch the workflow runs on (main)
#   HOMEBREW_BOTTLER_BUDGET_MINUTES  runner: stop starting new builds after this (150)
#   HOMEBREW_BOTTLER_HARD_STOP_MINUTES runner: kill a running build at this point (330)
#   HOMEBREW_GITHUB_API_TOKEN        runner: token for gh (uploads, re-dispatch)

require "digest"
require "fileutils"
require "json"
require "open3"
require "set"
require "time"
require "tmpdir"

if defined?(PkgVersion) # under `brew ruby` (the runner)
  require "utils/output"
  include Utils::Output::Mixin

  def compare_pkg_versions(a, b) = PkgVersion.parse(a) <=> PkgVersion.parse(b)
else # plain portable Ruby (the MacBook)
  def paint(code, text) = $stderr.tty? ? "\e[#{code}m#{text}\e[0m" : text
  def ohai(msg) = puts("#{paint("1;34", "==>")} #{paint(1, msg)}")
  def opoo(msg) = warn("#{paint(33, "Warning")}: #{msg}")
  def onoe(msg) = warn("#{paint(31, "Error")}: #{msg}")

  def odie(msg)
    onoe(msg)
    exit 1
  end

  # Homebrew-style "version_revision" comparison: numeric parts compare as
  # numbers, a trailing letter part is a pre-release ("1.0rc1" < "1.0").
  def compare_pkg_versions(a, b)
    (va, ra), (vb, rb) = [a, b].map { |s| s.match(/\A(.+?)(?:_(\d+))?\z/).captures }
    ta = va.scan(/\d+|[a-z]+/i)
    tb = vb.scan(/\d+|[a-z]+/i)
    [ta.size, tb.size].max.times do |i|
      x, y = ta[i], tb[i]
      # A missing part counts as 0 ("9.1" == "9.1.0"), but is newer than a
      # letter part ("1.0" > "1.0rc1").
      x ||= y.match?(/\A\d/) ? "0" : (return 1)
      y ||= x.match?(/\A\d/) ? "0" : (return -1)
      next if x == y

      xn, yn = x.match?(/\A\d/), y.match?(/\A\d/)
      return (xn ? 1 : -1) if xn != yn
      return xn ? x.to_i <=> y.to_i : x <=> y
    end
    ra.to_i <=> rb.to_i
  end
end

def newer_or_equal?(a, b) = compare_pkg_versions(a, b) >= 0

# Is our published bottle `rec` at least the version `entry` wants? Homebrew
# compares version_scheme first: a formula bumps it when its version goes
# backwards (openssl@3 moving from 3.6.x to the 3.5 LTS line).
def bottle_current?(rec, entry)
  return false unless rec

  scheme = rec["version_scheme"].to_i
  scheme == entry.scheme ? newer_or_equal?(rec["pkg_version"], entry.wanted) : scheme > entry.scheme
end

TAG = ENV.fetch("HOMEBREW_BOTTLER_TAG", "sequoia")
# Bottles built for an older macOS still pour on Sequoia; "all" is arch-independent.
COMPATIBLE_TAGS = ENV.fetch("HOMEBREW_BOTTLER_COMPATIBLE_TAGS", "all,sequoia,sonoma,ventura,monterey,big_sur").split(",").freeze
RELEASE = "bottles"
WORKFLOW = "build-bottles.yml"
CACHE = File.expand_path("~/Library/Caches/ibrew")
FORMULA_NAME = %r{\A[\w@+.\-/]+\z}
NEEDS_BUILD = %i[missing stale].freeze
STARTED = Time.now

# `brew ruby` runs with a minimal PATH; restore the caller's so brew, gh, curl resolve.
ENV["PATH"] = ENV["HOMEBREW_PATH"] if ENV["HOMEBREW_PATH"]
ENV["HOMEBREW_NO_ENV_HINTS"] = "1"

REPO = ENV["HOMEBREW_IBREW_REPO"] || odie("HOMEBREW_IBREW_REPO is not set (expected owner/repo)")
# brew strips GH_* and *TOKEN* variables; hand gh what it needs on the runner.
ENV["GH_REPO"] = REPO
ENV["GH_TOKEN"] ||= ENV["HOMEBREW_GITHUB_API_TOKEN"] if ENV["HOMEBREW_GITHUB_API_TOKEN"]

# status: :current  installed here at Homebrew's version (client only)
#         :external from a third-party tap (e.g. mongodb/brew); left to brew
#         :official homebrew/core still ships a bottle this Mac can pour
#         :ours     our release has a bottle at (at least) Homebrew's version
#         :stale    our release has a bottle, but an older version
#         :missing  no bottle anywhere
Entry = Struct.new(:name, :status, :wanted, :scheme, :ours, :installed, :target, keyword_init: true)

def run!(*cmd, env: {}, timeout: nil)
  ohai cmd.join(" ")
  # With a timeout the command gets its own process group, so the whole build
  # tree (make, clang, ...) can be stopped together.
  pid = Process.spawn(env, *cmd, **(timeout ? { pgroup: true } : {}))
  waiter = Process.detach(pid)
  unless waiter.join(timeout)
    %w[TERM KILL].each do |signal|
      Process.kill(signal, -pid) rescue nil # rubocop:disable Style/RescueModifier
      break if waiter.join(15)
    end
    raise "timed out after #{(timeout / 60).round} min: #{cmd.join(" ")}"
  end
  return if waiter.value.success?

  raise "command failed (exit #{waiter.value.exitstatus}): #{cmd.join(" ")}"
end

def read(*cmd, stdin: nil)
  out, status = Open3.capture2(*cmd, stdin_data: stdin.to_s)
  raise "command failed: #{cmd.first(3).join(" ")}" unless status.success?

  out
end

# --- Published bottles: assets + index.json on the "bottles" release --------

def asset_url(asset) = "https://github.com/#{REPO}/releases/download/#{RELEASE}/#{asset}"

# { "bottles" => { name => {pkg_version, filename, asset, sha256, built_at} },
#   "failed"  => { name => {pkg_version, reason, at} } }
def fetch_index
  data = Dir.mktmpdir do |dir|
    path = File.join(dir, "index.json")
    code = read("curl", "-sSL", "-o", path, "-w", "%{http_code}", "#{asset_url("index.json")}?t=#{Time.now.to_i}")
    if code == "200" then JSON.parse(File.read(path))
    elsif code == "404" then {} # nothing published yet
    else raise "could not download index.json from #{REPO} (HTTP #{code})"
    end
  end
  { "bottles" => data.fetch("bottles", {}), "failed" => data.fetch("failed", {}) }
end

def publish_index(index)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "index.json")
    File.write(path, JSON.pretty_generate(index.transform_values { _1.sort.to_h }))
    run!("gh", "release", "upload", RELEASE, path, "--clobber")
  end
end

# --- Formula metadata ------------------------------------------------------

# Caches `brew info --json=v2` results, reachable by name, alias or old name.
class Catalog
  def initialize
    @by_name = {}
  end

  def load(names)
    missing = names.uniq.reject { @by_name.key?(_1) }
    return if missing.empty?

    JSON.parse(read("brew", "info", "--json=v2", "--formula", *missing))["formulae"].each do |f|
      [f["name"], f["full_name"], *f["aliases"], *f["oldnames"]].each { @by_name[_1] = f }
    end
  end

  def [](name)
    load([name])
    @by_name.fetch(name) { raise "unknown formula: #{name}" }
  end
end

def pkg_version(info)
  version = info.dig("versions", "stable")
  info["revision"].to_i.positive? ? "#{version}_#{info["revision"]}" : version
end

def official_bottle?(info)
  (info.dig("bottle", "stable", "files")&.keys || []).intersect?(COMPATIBLE_TAGS)
end

# On the runner (client: false) only "is there a pourable bottle?" matters;
# on the MacBook an up-to-date installed keg means there is nothing to do.
def classify(info, index, client:, force: false)
  rec = index.dig("bottles", info["name"])
  entry = Entry.new(
    name: info["name"], wanted: pkg_version(info), scheme: info["version_scheme"].to_i, ours: rec&.fetch("pkg_version"),
    installed: info["installed"].map { _1["version"] }.max { |a, b| compare_pkg_versions(a, b) }, target: false
  )
  entry.status =
    # brew's own "outdated" knows about version_scheme, which the installed list doesn't carry.
    if client && !force && entry.installed && !info["outdated"] then :current
    elsif info["tap"] != "homebrew/core" then :external
    elsif official_bottle?(info) then :official
    elsif bottle_current?(rec, entry) then :ours
    elsif rec then :stale
    else :missing
    end
  entry
end

# Entries for `targets` and everything they need, dependencies first. On the
# runner, build dependencies of formulae that must be compiled are included.
def plan(targets, catalog, index, client:, force: [])
  return [] if targets.empty?

  closure = read("brew", "deps", "--union", "--full-name", *("--include-build" unless client), *targets).split
  catalog.load(targets + closure)

  order = []
  seen = {}
  visit = lambda do |name, target|
    info = catalog[name]
    if (entry = seen[info["name"]])
      entry.target ||= target
      next
    end

    entry = classify(info, index, client:, force: force.include?(info["name"]))
    entry.target = target
    seen[entry.name] = entry
    deps = info["dependencies"]
    deps += info["build_dependencies"] if !client && NEEDS_BUILD.include?(entry.status)
    deps.each { visit.(_1, false) }
    order << entry
  end
  targets.each { visit.(_1, true) }
  order
end

# Every formula `names` pulls in at runtime, recursively (canonical names).
def runtime_closure(names, catalog, acc = Set.new)
  names.each do |name|
    info = catalog[name]
    runtime_closure(info["dependencies"], catalog, acc) if acc.add?(info["name"])
  end
  acc
end

# Download one of our bottles (checksum-verified, cached) and pour it.
def pour(entry, index)
  rec = index["bottles"].fetch(entry.name)
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, rec["filename"])
  unless File.exist?(path) && Digest::SHA256.file(path).hexdigest == rec["sha256"]
    run!("curl", "-fL", "--retry", "3", "-o", path, asset_url(rec["asset"]))
    unless Digest::SHA256.file(path).hexdigest == rec["sha256"]
      FileUtils.rm_f(path)
      raise "checksum mismatch for #{rec["asset"]}"
    end
  end
  verb = entry.installed == rec["pkg_version"] ? "reinstall" : "install"
  # NO_INSTALLED_DEPENDENTS_CHECK stops brew from rebuilding dependents from
  # source after a library upgrade; outdated dependents get their own bottles
  # from this plan instead. DEVELOPER: since Homebrew 4.6, `brew install <file>`
  # only works in developer mode. As an env var for this one command it doesn't
  # turn developer mode on for good the way `brew ruby` does.
  run!("brew", verb, path, env: { "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" => "1", "HOMEBREW_DEVELOPER" => "1" })
  entry.installed = rec["pkg_version"]
end

# --- Runner: build and publish -------------------------------------------

def packages_txt
  File.readlines(File.join(__dir__, "..", "packages.txt"), chomp: true)
      .map { _1.sub(/#.*/, "").strip }.reject(&:empty?)
end

# Edits to homebrew/core formulae whose bottle build doesn't fit in one job.
# llvm's bottle build compiles LLVM four times for PGO (a faster clang); a plain
# source install compiles it once. Same features, slightly slower clang.
FORMULA_EDITS = {
  "llvm" => [/^(\s*)pgo_build = .*$/, '\1pgo_build = false'],
}.freeze

def edit_formula(name)
  return unless FORMULA_EDITS.key?(name)

  pattern, replacement = FORMULA_EDITS[name]
  info = JSON.parse(read("brew", "info", "--json=v2", "--formula", name))["formulae"].first
  path = File.join(read("brew", "--repository", info["tap"]).strip, info["ruby_source_path"])
  source = File.read(path)
  edited = source.sub(pattern, replacement)
  return opoo "#{name}: formula changed upstream, building it unedited" if edited == source

  ohai "#{name}: editing #{path} (#{edited[pattern].strip})"
  File.write(path, edited)
end

def build_bottle(entry, index, timeout:)
  name = entry.name
  run!("brew", "uninstall", "--ignore-dependencies", "--force", name) if entry.installed
  edit_formula(name)
  # --overwrite: the runner image ships its own copies of some tools (e.g.
  # /usr/local/bin/vcpkg), which would otherwise make `brew link` fail.
  run!("brew", "install", "--build-bottle", "--overwrite", name, timeout:)
  Dir.mktmpdir do |dir|
    Dir.chdir(dir) { run!("brew", "bottle", "--json", "--no-rebuild", name) }
    json = Dir["#{dir}/*.bottle.json"].first or raise "brew bottle wrote no JSON"
    data = JSON.parse(File.read(json)).values.first
    bottle = data.dig("bottle", "tags", TAG) or
      raise "expected a #{TAG} bottle, got #{data.dig("bottle", "tags").keys.join(", ")}"

    filename = bottle["local_filename"] || File.basename(Dir["#{dir}/*.tar.gz"].first)
    asset = filename.gsub(/[^\w.-]/, "_") # GitHub mangles e.g. "@" in asset names
    FileUtils.mv(File.join(dir, filename), File.join(dir, asset)) if asset != filename
    run!("gh", "release", "upload", RELEASE, File.join(dir, asset), "--clobber")

    old = index.dig("bottles", name, "asset")
    index["bottles"][name] = {
      "pkg_version"    => data.dig("formula", "pkg_version") || entry.wanted,
      "version_scheme" => entry.scheme,
      "filename"       => filename,
      "asset"          => asset,
      "sha256"         => bottle["sha256"],
      "built_at"       => Time.now.utc.iso8601,
    }
    index["failed"].delete(name)
    publish_index(index)
    run!("gh", "release", "delete-asset", RELEASE, old, "--yes") if old && old != asset
  end
  entry.status = :ours
  entry.ours = entry.installed = index["bottles"][name]["pkg_version"]
end

def minutes_from_start(env_name, default) = STARTED + (Integer(ENV.fetch(env_name, default)) * 60)

def build(requested)
  targets = requested.empty? ? packages_txt : requested
  catalog = Catalog.new
  index = fetch_index
  order = plan(targets, catalog, index, client: false)
  todo = order.select { NEEDS_BUILD.include?(_1.status) }
  ohai "#{todo.size} of #{order.size} formulae need an Intel bottle: #{todo.map(&:name).join(" ")}"

  prereqs = lambda do |entry|
    info = catalog[entry.name]
    runtime_closure(info["dependencies"] + info["build_dependencies"], catalog)
  end
  needed_here = todo.map(&prereqs).reduce(Set.new, :|)
  # No new builds after the budget; a running build is killed at the hard stop,
  # which leaves room before the job's 355 min timeout to record and re-dispatch.
  stop_starting = minutes_from_start("HOMEBREW_BOTTLER_BUDGET_MINUTES", "150")
  hard_stop = minutes_from_start("HOMEBREW_BOTTLER_HARD_STOP_MINUTES", "330")
  built = []
  failed = []
  postponed = []

  order.each do |entry|
    if entry.status == :ours && needed_here.include?(entry.name) && entry.installed != entry.ours
      pour(entry, index)
    elsif NEEDS_BUILD.include?(entry.status)
      known = index.dig("failed", entry.name)
      if (blockers = prereqs.(entry) & failed).any?
        opoo "#{entry.name}: skipped, depends on failed #{blockers.to_a.join(", ")}"
        failed << entry.name
      elsif requested.empty? && known && known["pkg_version"] == entry.wanted
        # Nightly runs don't retry a known failure; asking for it by name does.
        opoo "#{entry.name}: failed before at #{entry.wanted} (#{known["reason"]}), not retrying"
        failed << entry.name
      elsif Time.now > stop_starting
        postponed << entry.name
      else
        begin
          build_bottle(entry, index, timeout: hard_stop - Time.now)
          built << entry.name
        rescue => e
          index["failed"][entry.name] = {
            "pkg_version" => entry.wanted, "reason" => e.message[0, 200], "at" => Time.now.utc.iso8601,
          }
          publish_index(index)
          raise
        end
      end
    end
  rescue => e
    onoe "#{entry.name}: #{e.message}"
    failed << entry.name
  end

  if (summary = ENV["GITHUB_STEP_SUMMARY"])
    File.write(summary, <<~MD, mode: "a")
      ### Intel bottles (#{TAG})
      | | # | formulae |
      |---|---|---|
      | built | #{built.size} | #{built.join(" ")} |
      | failed | #{failed.size} | #{failed.join(" ")} |
      | postponed | #{postponed.size} | #{postponed.join(" ")} |
    MD
  end

  if postponed.any?
    if built.any?
      ohai "Out of time; continuing in a new run"
      run!("gh", "workflow", "run", WORKFLOW, "-f", "formulae=#{requested.join(" ")}")
    else
      opoo "Out of time before building anything; not re-dispatching"
    end
  end
  exit 1 if failed.any?
end

# --- MacBook: pour instead of compiling -----------------------------------

# Decide where a formula without an up-to-date official bottle comes from.
#
# entry.status is :ours (our bottle matches Homebrew's version), :stale (our
# bottle is older than Homebrew's version) or :missing (no bottle anywhere).
# Also available: entry.target (true if you asked for it by name, false if it
# is a dependency), entry.installed (version on this Mac, or nil),
# entry.wanted (Homebrew's version) and entry.ours (our bottle's version).
#
# Return one of:
#   :pour    download our bottle as it is (works for :ours and :stale)
#   :remote  build it on GitHub, wait for it, then pour it
#   :brew    let brew compile it on this Mac
#   :skip    leave it alone for now (anything that needs it is skipped too)
def choose_source(entry)
  # Default policy: never compile on the MacBook. An older (:stale) bottle is
  # not poured, because dependents built on the runner against the current
  # version could fail to load against an older library.
  entry.status == :ours ? :pour : :remote
end

def github_api(method, path, body = nil)
  token = read("security", "find-generic-password", "-s", "ibrew", "-a", REPO, "-w").strip
  # The token goes through stdin so it never shows up in `ps`.
  args = ["curl", "-fsS", "-X", method, "-H", "Accept: application/vnd.github+json", "--config", "-"]
  args += ["-d", JSON.generate(body)] if body
  out = read(*args, "https://api.github.com/repos/#{REPO}#{path}",
             stdin: "header = \"Authorization: Bearer #{token}\"\n")
  out.strip.empty? ? {} : JSON.parse(out)
end

def wait_for_bottles(entries)
  wait = Integer(ENV.fetch("HOMEBREW_IBREW_WAIT_MINUTES", "240")) * 60
  deadline = Time.now + wait
  dispatch = lambda do |list|
    github_api("POST", "/actions/workflows/#{WORKFLOW}/dispatches",
               { ref: ENV.fetch("HOMEBREW_IBREW_REF", "main"), inputs: { formulae: list.map(&:name).join(" ") } })
  end

  ohai "Requesting #{entries.size} bottle(s) from #{REPO}: #{entries.map(&:name).join(" ")}"
  requested_at = Time.now.utc
  dispatch.(entries)
  dispatches = 1
  loop do
    sleep 60
    index = fetch_index
    remaining = entries.reject { |e| bottle_current?(index.dig("bottles", e.name), e) }
    # Stop waiting for anything whose build failed after we asked for it.
    failed, remaining = remaining.partition do |e|
      (f = index.dig("failed", e.name)) && Time.parse(f["at"]) > requested_at
    end
    failed.each { |e| opoo "#{e.name}: build failed on GitHub (#{index.dig("failed", e.name, "reason")})" }
    entries -= failed
    return index if remaining.empty?

    if Time.now > deadline
      opoo "Gave up after #{wait / 60} min waiting for: #{remaining.map(&:name).join(" ")}"
      return index
    end

    active = %w[queued in_progress].sum do |state|
      github_api("GET", "/actions/workflows/#{WORKFLOW}/runs?status=#{state}&per_page=1")["total_count"]
    end
    if active.positive?
      puts "    waiting for #{remaining.size} bottle(s), #{active} run(s) active..."
    elsif dispatches < 2
      dispatch.(remaining) # a queued run can be superseded by a newer one; ask again
      dispatches += 1
    else
      opoo "Builds finished without: #{remaining.map(&:name).join(" ")} (see the repo's Actions tab)"
      return index
    end
  end
end

def split_formulae(names)
  return [[], []] if names.empty?

  json = JSON.parse(read("brew", "info", "--json=v2", *names))
  known = json["formulae"].flat_map { [_1["name"], _1["full_name"], *_1["aliases"], *_1["oldnames"]] }
  names.partition { known.include?(_1) }
end

def print_plan(order, decisions)
  current, rest = order.partition { _1.status == :current }
  ohai "Plan (#{TAG}): #{rest.size} to install, #{current.size} already up to date"
  rest.each do |e|
    note = case e.status
    when :official then "official bottle"
    when :external then "third-party tap, brew handles it"
    when :ours then "our bottle"
    when :stale then "our bottle is older (#{e.ours})"
    else "no bottle yet"
    end
    puts format("    %-8s %-30s %-16s %s", decisions[e.name] || "brew", e.name, e.wanted, note)
  end
end

def client(command, names)
  dry_run = ENV["HOMEBREW_IBREW_DRY_RUN"]
  run!("brew", "update") unless ENV["HOMEBREW_NO_AUTO_UPDATE"] || dry_run
  ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"

  catalog = Catalog.new
  formulae, others = split_formulae(names)
  formulae = formulae.map { catalog[_1]["name"] }
  targets = if command == "upgrade" && names.empty?
    JSON.parse(read("brew", "outdated", "--json=v2", "--formula"))["formulae"]
        .reject { _1["pinned"] }.map { _1["name"] }
  else
    formulae
  end

  index = fetch_index
  order = plan(targets, catalog, index, client: true, force: command == "reinstall" ? targets : [])
  work = order.reject { %i[current external official].include?(_1.status) }
  decisions = work.to_h { [_1.name, choose_source(_1)] }
  print_plan(order, decisions)
  return if dry_run

  remote = work.select { decisions[_1.name] == :remote }
  index = wait_for_bottles(remote) if remote.any?

  poured = []
  skipped = []
  work.each do |entry|
    decision = decisions[entry.name]
    next if decision == :brew

    rec = index["bottles"][entry.name]
    blocked = catalog[entry.name]["dependencies"].map { catalog[_1]["name"] } & skipped
    reason =
      if decision == :skip then "skipped by choose_source"
      elsif blocked.any? then "needs #{blocked.join(", ")}"
      elsif rec.nil? then "no bottle published"
      elsif decision == :remote && !bottle_current?(rec, entry) then "remote build missing"
      end
    if reason
      opoo "#{entry.name}: not installed (#{reason})"
      skipped << entry.name
      next
    end

    pour(entry, index)
    poured << entry.name
  rescue => e
    onoe "#{entry.name}: #{e.message}"
    skipped << entry.name
  end

  # Hand everything else (official bottles, casks, :brew choices) to brew,
  # leaving out what was poured or skipped so brew never compiles those.
  handled = poured + skipped
  if command == "upgrade" && names.empty?
    rest = targets - handled
    run!("brew", "upgrade", "--formula", *rest) if rest.any?
    run!("brew", "upgrade", "--cask")
  else
    rest = (formulae - handled) + others
    run!("brew", command, *rest) if rest.any?
  end

  ohai "Poured #{poured.size} bottle(s) from #{REPO}" if poured.any?
  exit 1 if skipped.any?
end

command, *args = ARGV
args.each { odie "invalid formula name: #{_1}" unless FORMULA_NAME.match?(_1) }
begin
  case command
  when "build" then build(args)
  when "install", "upgrade", "reinstall" then client(command, args)
  else odie "usage: bottler.rb build|install|upgrade|reinstall [formula ...]"
  end
rescue RuntimeError => e
  odie e.message # brew has usually printed the details already
rescue Interrupt
  exit 130
end
