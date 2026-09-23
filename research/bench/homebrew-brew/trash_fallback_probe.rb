# Probe: what Homebrew/brew's macOS trash fallback does to an item it cannot trash.
# Source: Homebrew/brew@3f12c3e (identical to installed /opt/homebrew@570982948a, checked with diff)
#   Library/Homebrew/extend/os/mac/cask/utils/trash.rb:16-38  (fallback: gain_permissions(path, ["-R"]))
#   Library/Homebrew/cask/utils.rb:95-153                      (chflags 000, chmod u+rwx, chmod -N, sudo chown)
# Everything happens under ARGV[0] (a scratch dir). Nothing outside it is touched, sudo is never run.
# Run: HOMEBREW_NO_AUTO_UPDATE=1 brew ruby trash_fallback_probe.rb <scratch-dir>
require "cask/utils/trash"

root = Pathname(ARGV.fetch(0)).realpath

def show(label, path)
  puts "  #{label}: #{`/bin/ls -ldOe #{path.to_s.inspect}`.lines.map(&:strip).join(" | ")}"
  path.children.each { |c| puts "    #{`/bin/ls -lOe #{c.to_s.inspect}`.lines.map(&:strip).join(" | ")}" } if path.directory?
end

# --- Case A: real code, real SystemCommand. Item is ours, its parent is read-only, so trashing fails.
parent = root/"ro_parent"
item = parent/"Helper"
item.mkpath
(item/"tool").write("x")
system "/bin/chmod", "0755", (item/"tool").to_s
system "/bin/chmod", "+a", "everyone deny delete", (item/"tool").to_s   # an ACL
system "/usr/bin/chflags", "uchg", (item/"tool").to_s                    # Finder "Locked"
system "/bin/chmod", "0555", parent.to_s
puts "Case A: untrashable item (read-only parent), real commands"
show("before", item)
trashed, untrashable = Cask::Utils::Trash.trash(item)
puts "  result: trashed=#{trashed.inspect} untrashable=#{untrashable.inspect}"
show("after ", item)
system "/bin/chmod", "0755", parent.to_s

# --- Case B: same flow for an item owned by someone else (e.g. root in /Library/PrivilegedHelperTools).
# Simulated: trash always fails, ownership_problem? is forced true (as lstat.uid 0 != euid gives), and SystemCommand.run only records.
log = []
fake = Module.new do
  define_method(:run) do |exe, **kw|
    log << "#{kw[:sudo] ? "sudo " : ""}#{exe} #{Array(kw[:args]).join(" ")}"
    nil
  end
end
SystemCommand.singleton_class.prepend(fake)
MacOS::FFI::Foundation.singleton_class.prepend(Module.new do
  def trash_item(_path) = nil
end)
# Real check first (read-only lstat of a root-owned dir), then force it true for the scratch item.
puts "  real ownership_problem?(/Library/PrivilegedHelperTools) = #{Cask::Utils.ownership_problem?(Pathname("/Library/PrivilegedHelperTools"), recursive: false)}"
Cask::Utils.singleton_class.prepend(Module.new do
  def ownership_problem?(*, **) = true
end)
other = root/"other_owner_item"
other.mkpath
puts "Case B: item owned by another uid, commands recorded not run"
trashed, untrashable = Cask::Utils::Trash.trash(other)
puts "  result: trashed=#{trashed.inspect} untrashable=#{untrashable.inspect}"
log.each { |l| puts "  ran: #{l.sub(root.to_s, "<scratch>")}" }

# Case B detail: call the same fallback directly to surface what the trash wrapper's bare `rescue` hides.
log.clear
begin
  Cask::Utils.gain_permissions(other, ["-R"], SystemCommand) { raise "trash failed" }
rescue => e
  puts "  gain_permissions raised: #{e.class}: #{e.message}"
end
log.each { |l| puts "  ran: #{l.sub(root.to_s, "<scratch>")}" }
