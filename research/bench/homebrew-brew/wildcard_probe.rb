# Probe: Homebrew/brew AbstractUninstall#find_launchctl_with_wildcard
# Source: Homebrew/brew@3f12c3e Library/Homebrew/cask/artifact/abstract_uninstall.rb:172-181
# (identical to the installed /opt/homebrew@570982948a, checked with diff).
# Read-only: calls `launchctl list` / `launchctl print`, never removes anything.
# Run: HOMEBREW_NO_AUTO_UPDATE=1 brew ruby research/bench/homebrew-brew/wildcard_probe.rb <pattern>...
require "cask/artifact/zap"

artifact = Cask::Artifact::Zap.allocate # skip initialize: no Cask needed for this method
ARGV.each do |pattern|
  found = artifact.find_launchctl_with_wildcard(pattern)
  regex = /\A#{Regexp.escape(pattern).gsub("\\*", ".*")}\z/
  listed = `/bin/launchctl list`.lines.drop(1).map { |l| l.chomp.split(/\s+/) }
                                 .select { |_, _, id| id&.match?(regex) }
  puts "pattern=#{pattern}"
  puts "  brew find_launchctl_with_wildcard -> #{found.inspect}"
  puts "  same pattern over user-domain launchctl list (any PID) -> #{listed.map { |pid, _, id| "#{id} (pid #{pid})" }.inspect}"
end
