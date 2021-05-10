#!/usr/bin/ruby

if ARGV.length != 3
	abort "usage: #$0 <dumpfile> <blocklen> <ooblen>"
end

tg = ARGV.shift
blen = Integer(ARGV.shift)
olen = Integer(ARGV.shift)

File.open(tg, 'rb') { |fd|
	until fd.eof?
		pre_pos = fd.pos
		fd.pos += blen
		oob = fd.read(olen).to_s
		puts "#{'%06X' % pre_pos} #{oob.unpack('H*').first}"
	end
}
