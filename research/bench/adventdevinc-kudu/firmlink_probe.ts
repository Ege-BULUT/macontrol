// Probe: Kudu's analyzer walks '/' (resolveRootPath accepts '/', disk-analyzer.ipc.ts:214-223) and
// never checks device, inode or mount point. Firmlinked Data-volume paths are therefore reachable
// twice from '/'. Measures one bounded subtree through both routes. Run: node firmlink_probe.ts
import { measureDirectorySize } from './measure.ts'
import { statSync } from 'fs'
const rel = 'Users/egeb/projects/macontrol/research/sources/adventdevinc-kudu'
const a = '/' + rel, b = '/System/Volumes/Data/' + rel
const [sa, sb] = [await measureDirectorySize(a), await measureDirectorySize(b)]
const ia = statSync(a), ib = statSync(b)
console.log(`${a}\n  bytes=${sa} dev=${ia.dev} ino=${ia.ino}`)
console.log(`${b}\n  bytes=${sb} dev=${ib.dev} ino=${ib.ino}`)
console.log(`same dev+ino: ${ia.dev === ib.dev && ia.ino === ib.ino}; a walk of '/' sums both: ${sa + sb} bytes for ${sa} bytes on disk`)
