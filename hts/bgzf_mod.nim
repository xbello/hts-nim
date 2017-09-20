import "hts_concat"
import strutils

type
  BGZ* = ref object of RootObj
    cptr*: ptr BGZF

  CSI* = ref object of RootObj
    idx*: ptr hts_idx_t
    cnf*: tbx_conf_t

  BGZI* = ref object of RootObj
    bgz*: BGZ
    csi*: CSI
    path: string
    chroms*: seq[string]
    last_start: int

proc idx_set_meta*(idx: ptr hts_idx_t; tc: ptr tbx_conf_t; chroms: string): cint {.cdecl.} =
  var x: array[7, uint32]
  x[6] = cast[uint32](chroms.len)
  var meta = new_seq[uint8](28 + chroms.len)
  copyMem(cast[pointer](meta.addr), cast[pointer](x.addr), 28)

  var s = new_string(chroms.len)
  s = chroms

  var vm = meta[28..len(meta)]
  copyMem(cast[pointer](vm.addr), cast[pointer](s.addr), chroms.len)
  hts_idx_set_meta(idx, cint(32), cast[ptr uint8](meta), cint(0))


proc open*(b: var BGZ, path: string, mode: string) =
  if b == nil:
    b = BGZ()
  b.cptr = bgzf_open(cstring(path), cstring(mode))

proc close*(b: BGZ): int =
  return int(bgzf_close(b.cptr))

proc write*(b: BGZ, line: string): int =
  return int(bgzf_write(b.cptr, cstring(line), csize(line.len)))

proc write_line*(b: BGZ, line: string): int =
  var r = int(bgzf_write(b.cptr, cstring(line), csize(line.len)))
  if r > 0:
    if int(bgzf_write(b.cptr, cstring("\n"), csize(1))) < 0:
      return -1
  return r + 1

proc read_line*(b: BGZ, line:var ptr kstring_t): int =
  bgzf_getline(b.cptr, cint(10), line)

proc flush*(b: BGZ): int =
  return int(bgzf_flush(b.cptr))

proc tell*(b: BGZ): uint64 =
  return uint64(bgzf_tell(b.cptr))

# these are all 1-based.
proc new_csi*(seq_col: int, start_col: int, end_col: int): CSI =
  var c = CSI()
  c.idx = hts_idx_init(0, HTS_FMT_CSI, 0, 14, 5)
  # automatically set the comment char to '#'
  c.cnf = tbx_conf_t(preset: int32(0), sc: int32(seq_col), bc: int32(start_col), ec: int32(end_col), meta_char: int32(35), line_skip: int32(0))
  return c

proc add*(c: CSI, tid: int, start: int, stop: int, offset:uint64): int =
  return int(hts_idx_push(c.idx, cint(tid), cint(start), cint(stop), offset, 1))

proc finish*(c: CSI, offset: uint64) =
  hts_idx_finish(c.idx, offset)

proc save*(c: CSI, path: string) =
  hts_idx_save(c.idx, cstring(path), HTS_FMT_CSI)

# int l_meta, uint8_t *meta, int is_copy
proc set_meta*(c: CSI, chroms: seq[string]): int =
  var chrom_string = ""
  for chrom in chroms:
    chrom_string &= chrom
    chrom_string.add('\0')
  idx_set_meta(c.idx, c.cnf.addr, chrom_string)

proc wopen_bgzi*(path: string, seq_col: int, start_col: int, end_col: int): BGZI =
  var b: BGZ
  b.open(path, "w")
  var bgzi = BGZI(bgz:b, csi: new_csi(seq_col, start_col, end_col), path:path)
  bgzi.chroms = new_seq[string]()
  bgzi.last_start = -100000
  return bgzi

proc write_interval*(b: BGZI, line: string, chrom: string, start: int, stop: int): int =
  if b.last_start < 0:
    b.chroms.add(chrom)
  if chrom != b.chroms[len(b.chroms)-1]:
    b.chroms.add(chrom)
  elif start < b.last_start:
    stderr.write_line("[hts-nim] starts out of order for:", b.path, " in:", line)
  var r = b.bgz.write_line(line)
  if b.csi.add(len(b.chroms), start, stop, b.bgz.tell()) < 0:
    stderr.write_line("[hts-nim] error adding to csi index")
    quit()
  return r

proc close*(b: BGZI): int =
   discard b.bgz.flush()
   b.csi.finish(b.bgz.tell())
   discard b.csi.set_meta(b.chroms)
   if b.bgz.close() < 0:
     stderr.write_line("[hts-nim] error closing bgzf")
     quit()
 
   b.csi.save(b.path)
   hts_idx_destroy(b.csi.idx)
