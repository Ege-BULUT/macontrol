# Probe: does Homebrew/brew's Cask::Pkg#uninstall check whether a BOM file also belongs to another receipt?
# Source: Homebrew/brew@3f12c3e Library/Homebrew/cask/pkg.rb:29-60 (uninstall), :74-99 (BOM lists)
# (identical to installed /opt/homebrew@570982948a, checked with diff).
# READ-ONLY: only calls the list methods (pkgutil --files / --pkg-info-plist). Never calls #uninstall.
# Run: HOMEBREW_NO_AUTO_UPDATE=1 brew ruby pkg_shared_probe.rb <pkg-id-to-remove> [regex-of-other-receipts]
require "cask/pkg"

target = ARGV.fetch(0)
pkg = Cask::Pkg.new(target, SystemCommand)
to_rm = pkg.pkgutil_bom_files # exactly what #uninstall pipes into `sudo xargs -0 rm` (pkg.rb:30-38)

others = `/usr/sbin/pkgutil --pkgs`.split.grep(Regexp.new(ARGV.fetch(1, "."))) - [target] # optional filter keeps the stat count bounded
owners = Hash.new { |h, k| h[k] = [] }
others.each do |id|
  other = Cask::Pkg.new(id, SystemCommand)
  other.pkgutil_bom_files.each { |f| owners[f.to_s] << id }
end
shared = to_rm.select { |f| owners.key?(f.to_s) }
puts "receipt=#{target}"
puts "  files #uninstall would rm: #{to_rm.size}"
puts "  of those, also listed by another installed receipt: #{shared.size}"
shared.first(3).each { |f| puts "    #{f} <- also #{owners[f.to_s].join(", ")}" }
