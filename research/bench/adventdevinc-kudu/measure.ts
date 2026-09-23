// Verbatim copy of Kudu@0ef4292 src/main/ipc/disk-analyzer.ipc.ts:127-150 (measureDirectorySize)
import { readdir, stat } from 'fs/promises'
import { join } from 'path'
export async function measureDirectorySize(dirPath: string): Promise<number> {
  let size = 0
  try {
    const entries = await readdir(dirPath, { withFileTypes: true })
    for (const entry of entries) {
      try {
        const fullPath = join(dirPath, entry.name)
        if (entry.isDirectory()) {
          size += await measureDirectorySize(fullPath)
        } else {
          const s = await stat(fullPath)
          // Do not count or follow directory symlinks/junctions.
          if (!s.isDirectory()) size += s.size
        }
      } catch {
        // Skip
      }
    }
  } catch {
    // Skip
  }
  return size
}

