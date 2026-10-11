import gleeunit/should
import jantar_core/parse

const diskstats =
  " 259       0 nvme0n1 46373 7063 3706568 6365 7660 1293 273991 1725 0 2852 8111 0 0 0 0 136 20
 254       0 dm-0 45000 0 3600000 6000 7000 0 270000 1700 0 2800 8000 0 0 0 0 0 0
"

const vmstat =
  "nr_free_pages 123
pswpin 7
pswpout 42
pgfault 99
"

const io_stat =
  "259:0 rbytes=23912448 wbytes=17928192 rios=3420 wios=547 dbytes=0 dios=0
254:0 rbytes=1000 wbytes=2000 rios=1 wios=2 dbytes=0 dios=0
"

pub fn diskstats_test() {
  parse.diskstats(diskstats, "nvme0n1")
  |> should.equal(Ok(#(3_706_568 * 512, 273_991 * 512)))
  parse.diskstats(diskstats, "sda") |> should.equal(Error(Nil))
}

pub fn swap_pages_test() {
  parse.swap_pages(vmstat) |> should.equal(#(7, 42))
}

pub fn cgroup_io_test() {
  parse.cgroup_io(io_stat, "254:0") |> should.equal(#(1000, 2000))
  parse.cgroup_io(io_stat, "8:0") |> should.equal(#(0, 0))
}
