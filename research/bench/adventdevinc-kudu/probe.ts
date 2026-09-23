// Probe: Kudu@0ef4292 folderMatchesProgram/isSafeFolder (copied verbatim from
// src/main/services/program-uninstaller.ts:367-419) against macOS-style names.
// Pure string matching; touches no files. Run: node probe.ts
import { folderMatchesProgram, isSafeFolder } from './matcher.ts'
// publisher = system_profiler obtained_from, as in platform/darwin/commands.ts:161
const cases: Array<[string, string, string]> = [
  ['Logi Options+', 'identified_developer', 'Logic'],
  ['Firefox Developer Edition', 'identified_developer', 'Firefox'],
  ['Brave Browser Beta', 'identified_developer', 'BraveSoftware'],
  ['Affinity Photo 2', 'mac_app_store', 'Affinity Designer 2'],
  ['Postman Agent', 'identified_developer', 'Postman'],
  ['Notion Calendar', 'identified_developer', 'Notion'],
  ['Unity Hub', 'identified_developer', 'Unity'],
  ['Steam Link', 'mac_app_store', 'Steam'],
  // controls: expected match / expected no match
  ['Obsidian', 'identified_developer', 'obsidian'],
  ['Obsidian', 'identified_developer', 'Signal'],
]
let fp = 0
for (const [app, pub, folder] of cases) {
  const hit = !isSafeFolder(folder) && folderMatchesProgram(folder, { displayName: app, publisher: pub, installLocation: '' })
  console.log(`${hit ? 'MATCH   ' : 'no match'}  uninstall "${app}" -> ~/Library/Application Support/${folder}`)
  if (hit && app !== 'Obsidian') fp++
}
console.log(`false-positive owners: ${fp}/8`)
