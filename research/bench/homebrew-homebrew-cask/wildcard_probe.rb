# Runs Homebrew's own AbstractUninstall#find_launchctl_with_wildcard
# (Library/Homebrew/cask/artifact/abstract_uninstall.rb:173-181 @ brew 570982948a)
# against a FAKE `launchctl list` output. Nothing on the system is read or changed.
#
#   HOMEBREW_NO_AUTO_UPDATE=1 brew ruby research/bench/homebrew-homebrew-cask/wildcard_probe.rb
require "cask/artifact/zap"

FAKE_LIST = <<~EOS
  PID\tStatus\tLabel
  -\t0\tcom.wacom.TabletDriver.agent
  4242\t0\tcom.wacom.TabletDriverUI
  777\t0\torg.other.com.wacom.TabletDriverHelper
  -\t0\tcom.paragon-software.ntfs.notification-agent
  555\t0\tapplication.com.paulpacifico.shutterencoder.1234.5678
EOS

zap = Cask::Artifact::Zap.allocate # skip Cask setup; the method only needs system_command!
zap.define_singleton_method(:system_command!) do |*_args, **_kw|
  Struct.new(:stdout).new(FAKE_LIST)
end

%w[com.wacom.TabletDriver* com.paragon-software.ntfs*].each do |pattern|
  found = zap.find_launchctl_with_wildcard(pattern)
  anchored = FAKE_LIST.lines.drop(1).map { |l| l.split("\t").last.chomp }
                      .grep(/\A#{Regexp.escape(pattern).gsub("\\*", ".*")}\z/)
  puts "#{pattern}\n  brew resolves : #{found.inspect}\n  exists (anchored, any state): #{anchored.inspect}"
end
