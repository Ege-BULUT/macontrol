// Verbatim extract of AdventDevInc/kudu@0ef4292 src/main/services/program-uninstaller.ts:367-419 (MIT, (c) 2026 Advent Development Inc), for probe.ts only.
import { SAFE_FOLDER_NAMES, SAFE_PREFIXES } from './safelist.ts'
type InstalledProgram = { displayName: string; publisher: string; installLocation: string }
const basename = (p: string) => p.split('/').pop() ?? ''
export function isSafeFolder(folderName: string): boolean {
  const lower = folderName.toLowerCase()
  if (SAFE_FOLDER_NAMES.has(lower)) return true
  for (const prefix of SAFE_PREFIXES) {
    if (lower.startsWith(prefix)) return true
  }
  if (lower.startsWith('.')) return true
  if (/^\{[0-9a-f-]+\}$/i.test(folderName)) return true
  return false
}

export function folderMatchesProgram(folderName: string, program: InstalledProgram): boolean {
  const lower = folderName.toLowerCase()
  const nameTokens: string[] = []

  // Program name and its parts
  const name = program.displayName.toLowerCase()
  if (name.length >= 3) {
    nameTokens.push(name)
    const withoutVersion = name.replace(/\s+[\d.]+\s*$/, '').trim()
    if (withoutVersion.length >= 3 && withoutVersion !== name) nameTokens.push(withoutVersion)
    const firstWord = name.split(/[\s\-_.()]+/)[0]
    if (firstWord && firstWord.length >= 3) nameTokens.push(firstWord)
  }

  // Publisher
  const pub = program.publisher.toLowerCase()
  if (pub.length >= 3) {
    nameTokens.push(pub)
    const pubFirst = pub.split(/[\s\-_.()]+/)[0]
    if (pubFirst && pubFirst.length >= 3) nameTokens.push(pubFirst)
  }

  // Install location folder name
  if (program.installLocation) {
    const folder = basename(program.installLocation).toLowerCase()
    if (folder.length >= 2) nameTokens.push(folder)
  }

  for (const token of nameTokens) {
    if (token.length >= 4 && lower.length >= 4) {
      if (token.includes(lower) || lower.includes(token)) return true
    }
    if (token.length >= 4) {
      if (lower.startsWith(token) || lower.endsWith(token)) return true
    }
    if (lower.length >= 4) {
      if (token.startsWith(lower) || token.endsWith(lower)) return true
    }
  }

  return false
}
