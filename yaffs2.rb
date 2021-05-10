#!/usr/bin/ruby

class YaFFS2
	# yaffs is a sequence of chunks
	# chunk can be file data or file header (check tags in the oob data)
	# if a part of a file is rewritten (works for header too), a new chunk is created and stored elsewhere in the flash
	# if the chunk is stored in the same flash block, it has the same blockseq but later is better
	# if it is stored in another block, the blockseq will be incremented
	# to delete a file, append a new header with size = 0 and name = 'unlinked' / 'deleted' and parent_id = 3 / 4
	# filesystem hierarchy is only stored in the oob section, with parentid links

	attr_accessor :raw, :chunksize, :oobsize, :oobfmt
	attr_accessor :chunk, :oob
	attr_accessor :obj_headers, :obj_id_idx, :fs_tree, :root_ids
	def initialize(raw, chunksize=512, oobsize=chunksize/512*16)
		@raw = raw
		@chunksize = chunksize
		@oobsize = oobsize
	end

	# read all chunks from the media, populate @chunk and @oob
	def read_chunks
		sz = @chunksize + @oobsize
		@chunk = []
		@oob = []
		(@raw.length/sz).times { |i|
			@chunk << @raw[i*sz, @chunksize]
			@oob << parse_oob(@raw[i*sz+@chunksize, @oobsize], @chunk.last)
		}
	end

	# helper function, strip all repetitions of byte at the end of str
	def str_strip_end(str, byte)
		ary = str.unpack('C*')
		len = ary.length
		len -= 1 while len >= 1 and ary[len-1] == byte
		str[0, len]
	end

	# parse one raw oob, return a hash
	# will parse the chunk data if oob shows its a metadata chunk
	# TODO you may need to adapt that to your specific OOB encoding
	def parse_oob(oob, chunk)
		blockstate, chunkid, objectid, nbytes, blockseq = oob.unpack('CNNnN')
		tag = {
			#:raw => oob,
			:blockstate => blockstate,	# is chunk valid ? 0xff ok, else nok
			:chunkid => chunkid,		# sequence nr of chunk in file data; 1st data chunk = id 1, header = id 0
			:objectid => objectid,		# file identifier (all chunks of a file have same objid)
			:nbytes => nbytes,		# size of chunk (max, except for last chunk of file)
			:blockseq => blockseq		# distinguish newer versions of a chunk in another block (higher = newer)
		}

		if tag[:chunkid] == 0
			objtype, parentid, _name_cksum = chunk.unpack('NNn')
			fname = str_strip_end(chunk[10, 256], 0)
			tag.update :parentid => parentid,	# objectid of containing folder
				:objtype => objtype,	# 1: file, 3: directory
				:fname => fname
		end

		# yaffs1
		# XXX defined as a bitfield, maybe endianness is wrong
		# dw1, dw2 = oob.unpack('NN')
		# :chunkid  => ((dw1 >>  0) & ((1 << 20) - 1)),
		# :serialnr => ((dw1 >> 20) & ((1 <<  2) - 1)),
		# :nbytes   => ((dw1 >> 22) & ((1 << 10) - 1)),
		# :objectid => ((dw2 >>  0) & ((1 << 18) - 1)),

		tag
	end

	# rebuild the folder structure
	# populate @fs_tree, @obj_id_idx, @obj_headers, @root_ids
	def rebuild_fs
		@fs_tree = {}	# { id => [child_id] }
		@obj_id_idx = {}	# id => [all chunk indexes in @oob/@chunk]
		@obj_headers = {}	# id => [all header oobs]
		@oob.each_with_index { |oob, idx|
			if oob[:objectid]
				(@obj_id_idx[oob[:objectid]] ||= []) << idx
			end

			if oob[:objtype]
				(@obj_headers[oob[:objectid]] ||= []) << oob
				(@fs_tree[oob[:parentid]] ||= []) << oob[:objectid]
			end
		}

		@root_ids = @fs_tree.keys - @fs_tree.values.flatten
	end

	# dump the @fs_tree to stdout
	# dump the object_id hierarchy, and for each obj_id dump all names available
	def dump_fs_tree
		@root_ids.sort.each { |root_id|
			dump_fs_tree_rec(root_id)
		}
	end

	def dump_fs_tree_rec(id, indent='')
		names = @obj_headers[id].to_a.map { |oob| oob[:fname].inspect + (oob[:objtype] == 3 ? '/' : '') }
		puts "#{indent}#{id} #{names.uniq.sort.join(' ')}"
		@fs_tree[id].to_a.uniq.sort.each { |sid| dump_fs_tree_rec(sid, indent + '    ') }
	end

	# return and array of indexes into @chunk/@oob
	# the array is the sequence of chunks related to one object_id sorted by modification time
	# i.e. sorted by blockseq, with same blockseq = sorted by raw offset
	def obj_idx_sorted(obj_id)
		by_seq = {}
		@obj_id_idx[obj_id].to_a.each { |idx|
			seq = @oob[idx][:blockseq]
			(by_seq[seq] ||= []) << idx
		}
		by_seq.keys.sort.map { |seq| by_seq[seq] }.flatten
	end

	# extract the various content of the file through time
	# each state is stored in objid_<object_id>/<serial_state_nr>_<parent_object_id>_<saved_filename>
	# save the log in <dir>/log
	def extract_file_history(obj_id)
		serial_nr = 0
		last_oob = nil
		dirty = {}	# block indexes that were changed from last saved file
		content = {}	# chunk content, with correct index
				# content[0] is file data 0..2048, content[4] is file 8192..10240 (if chunksize==2048)
		# dump current state to disk when we come across a new metadata oob
		# or a dirty block is rewritten (dump before rewrite)

		clean_name = lambda { |n|
			n.gsub(/[^a-zA-Z0-9_.-]/) { |o| o.unpack('H*').first }
		}

		obj_idx = obj_idx_sorted(obj_id)
		all_names = obj_idx.map { |idx| clean_name[@oob[idx][:fname].to_s] } - ['unlinked', 'deleted', '']

		dirname = "objid_#{obj_id}_#{all_names.compact.uniq.join('_')}"
		Dir.mkdir(dirname)	# raise if already exists
		puts dirname

		do_dump = lambda {
			if last_oob
				fname = clean_name[last_oob[:fname]]
				curname = "#{'%04d' % serial_nr}_#{last_oob[:parentid]}_#{fname}"
			else
				curname = "#{'%04d' % serial_nr}_unk"
			end
			File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts "dumping #{curname}" }
			File.open(File.join(dirname, curname), 'wb') { |fd|
				content.keys.sort.each { |i|
					next if i == 0	# first chunkid = 1
					fd.pos = i*@chunksize
					fd.write content[i]
				}
				fd.truncate(last_oob[:nbytes]) if last_oob
			}
			serial_nr += 1
			dirty.clear
		}

		dump = lambda {
			if last_oob and last_oob[:nbytes] and dirty.keys.max.to_i*@chunksize > last_oob[:nbytes]
				nbytes = last_oob.delete(:nbytes)
				last_oob[:nbytes] = dirty.keys.max*@chunksize
				do_dump[]
				last_oob[:nbytes] = nbytes
			end
			do_dump[]
		}

		prev_blockseq = nil
		obj_idx.each { |idx|
			oob = @oob[idx]
			if oob[:blockseq] != prev_blockseq
				File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts } if prev_blockseq
				prev_blockseq = oob[:blockseq]
			end
			if oob[:chunkid]
				# data chunk
				if dirty[oob[:chunkid]]
					dump[]
				end
				dirty[oob[:chunkid]] = true

				chk = @chunk[idx]
				content[oob[:chunkid]] = chk[0, oob[:nbytes]]

				File.open(File.join(dirname, 'log'), 'a') { |fd|
					fd.puts oob.inspect, "#{chk[0, 32].inspect}#{'...' if chk.length > 32}"
				}
			else
				# metadata chunk
				last_oob = oob
				File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts oob.inspect }
				dump[]
			end
		}
		dump[] if not dirty.empty?
	end

	# turn a yaffs dump generated with 'yaffs.rb -a'
	# eg objid_123/0000_103_toto.txt
	# into an actual fs tree, eg root/tmp/toto.txt
	def fulldump_to_tree
		all = []

		Dir['objid_*'].each { |oid|
			next if oid !~ /objid_(\d+)_/
			id = $1.to_i

			(Dir.entries(oid) - ['.', '..', 'log']).each { |ent|
				next if ent =~ /^(\d+)_unk$/
				if ent !~ /^(\d+)_(\d+)_(.*)$/
					puts "unk entry #{id} #{ent}"
					next
				end
				idx = $1.to_i
				parentid = $2.to_i
				basename = $3

				all << ["#{oid}/#{ent}", id, idx, parentid, basename]
			}
		}

		if all.empty?
			puts "please run -a beforehand"
			return
		end

		dirs_id = all.map { |path, id, idx, parentid, basename| parentid }.uniq
		roots_id = dirs_id.find_all { |did| !all.find { |path, id, idx, parentid, basename| id == did } }
		rroots_id = roots_id - [3, 4]	# deleted, unlinked
		puts "bad roots #{roots_id.inspect}" if rroots_id.length != 1

		rec = lambda { |curid, curpath, curparentid|
			cur = all.find_all { |path, id, idx, parentid, basename| id == curid and parentid == curparentid }
			basenames = cur.map { |path, id, idx, parentid, basename| basename }.uniq
			basenames << 'root' if basenames.empty?

			clds = all.find_all { |path, id, idx, parentid, basename| parentid == curid }
			if clds.empty?
				cur.each { |path, id, idx, parentid, basename|
					File.link(path, File.join(curpath, "#{basename}_#{idx}_#{id}"))
				}
			else
				# directory
				if basenames.length != 1
					puts "dir with multiple names: #{curid} #{basenames.inspect}"
				else
					b = basenames.first
					b = "objid_#{curid}" if b == ''
					subdir = File.join(curpath, b)
					Dir.mkdir(subdir)
					puts subdir
					clds.map { |path, id, idx, parentid, basename| id }.uniq.each { |id| rec[id, subdir, curid] }
				end
			end
		}

		rec[rroots_id.first, '.', 0]
	end

	# prevent ruby crash when raising an exception
	def inspect
		"#<YaFFS2>"
	end
end

if $0 == __FILE__
	tg = ARGV.shift
	abort "usage: yaffs <dumpfile> [<obj_id>|-a|-r]" if not File.exist?(tg)

	chunksize = (ENV['yaffs_chunklen'] || 2048).to_i
	obj_id = ARGV.shift

	raw = File.open(tg, 'rb') { |fd| fd.read }

	yaffs = YaFFS2.new(raw, chunksize)
	puts "read_chunks" if $VERBOSE
	yaffs.read_chunks
	puts "rebuild fs" if $VERBOSE
	yaffs.rebuild_fs

	case obj_id
	when '-a'
		yaffs.obj_id_idx.keys.sort.each { |id|
			yaffs.extract_file_history(id)
		}
	when '-r'
		yaffs.fulldump_to_tree
	when /^\d+$/
		yaffs.extract_file_history(obj_id.to_i)
	when nil
		yaffs.obj_headers.sort.each { |k, v| v.each { |hdr| p hdr } } if $VERBOSE
		yaffs.dump_fs_tree
	else
		puts "usage: yaffs <dumpfile> [<obj_id>|-a|-r]"
	end
end
