module main

import os
import flag
import json
import time

fn C.fsync(fd int) int
fn C._commit(fd int) int // idk about that pls test it

struct CopyState {
pub mut:
	src_size u64
	copied   u64
}

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vopy')
	fp.version('1.0.1')
	fp.description('Resumable bit-by-bit file copy with checksum integrity.')
	fp.skip_executable()

	recursive := fp.bool('recursive', `r`, false, 'Copy directories recursively')
	force := fp.bool('force', `f`, false, 'Force overwrite, skip previous resume metadata')
	interactive := fp.bool('interactive', `i`, false, 'Prompt before overwriting/resuming')
	no_preserve := fp.bool('no-preserve', `n`, false, 'Do not preserve file modification time (mtime)')
	verbose := fp.bool('verbose', `v`, false, 'Explain what is being done')
	size_only := fp.bool('size-only', `s`, false, 'Skip files if size matches, ignoring modification time')
	sync_interval := fp.int('sync-interval', `t`, 5, 'Time interval in seconds to sync metadata on disk')
	smart_overwrite := fp.bool('smart-overwrite', `m`, false, 'Only overwrite changed blocks to preserve disk writes')
	min_resume_size := fp.int('min-resume-size', `l`, 10485760, 'Minimum file size in bytes to enable resume metadata (default: 10MB)')

	positional := fp.finalize() or {
		eprintln('CLI Argument Error: ${err}')
		exit(1)
	}

	if positional.len != 2 {
		println(fp.usage())
		exit(1)
	}

	src := positional[0]
	dst := positional[1]
	preserve := !no_preserve

	if os.is_dir(src) {
		if !recursive {
			eprintln("vopy: -r not specified; omitting directory '${src}'")
			exit(1)
		}
		mut final_dst := dst
		if !dst.ends_with(os.file_name(src)) {
			final_dst = os.join_path(dst, os.file_name(src))
		}
		copy_dir(src, final_dst, force, interactive, preserve, verbose, size_only, sync_interval, smart_overwrite, min_resume_size) or {
			eprintln('Directory copy error: ${err}')
			exit(1)
		}
	} else {
		mut final_dst := dst
		if os.is_dir(dst) {
			final_dst = os.join_path(dst, os.file_name(src))
		}
		copy_file(src, final_dst, force, interactive, preserve, verbose, size_only, sync_interval, smart_overwrite, min_resume_size) or {
			eprintln('File copy error: ${err}')
			exit(1)
		}
	}
}

fn copy_file(src string, dst string, force bool, interactive bool, preserve bool, verbose bool, size_only bool, sync_interval int, smart_overwrite bool, min_resume_size int) ! {
	if !os.exists(src) {
		return error("Source file '${src}' does not exist.")
	}

	meta_path := dst + '.resume'
	tmp_meta_path := meta_path + '.tmp'
	src_size := os.file_size(src)
	use_resume := src_size >= u64(min_resume_size)

	if os.exists(dst) && !force {
		if os.file_size(dst) == src_size && (!use_resume || !os.exists(meta_path)) {
			if !smart_overwrite && (size_only || os.file_last_mod_unix(src) == os.file_last_mod_unix(dst)) {
				if verbose {
					println("Skipping completed file: '${src}' -> '${dst}'")
				}
				return
			}
		}
	}

	if os.exists(dst) && interactive {
		ans := os.input("vopy: overwrite/resume '${dst}'? (y/n): ")
		if ans.trim_space().to_lower() != 'y' {
			if verbose {
				println("Skipping: ${src} -> ${dst}")
			}
			return
		}
	}

	if force && os.exists(meta_path) {
		os.rm(meta_path) or {}
	}

	mut state := CopyState{
		src_size: src_size
		copied: 0
	}

	if use_resume && os.exists(meta_path) {
		meta_raw := os.read_file(meta_path) or { '' }
		if meta_raw != '' {
			parsed_state := json.decode(CopyState, meta_raw) or { state }
			if parsed_state.src_size == src_size {
				state.copied = parsed_state.copied
				if verbose {
					println("Resuming: '${src}' to '${dst}' from byte ${state.copied}/${src_size}")
				}
			}
		}
	} else if verbose {
		println("Copying: '${src}' -> '${dst}'")
	}

	if !os.exists(dst) || (use_resume && !os.exists(meta_path)) || (!use_resume && os.file_size(dst) != src_size) {
		mut f := os.create(dst) or { return err }
		f.close()
	}

	mut src_file := os.open(src) or { return err }
	defer { src_file.close() }

	mut dst_file := os.open_file(dst, 'r+', 0o666) or { return err }
	defer { dst_file.close() }

	src_file.seek(i64(state.copied), .start) or { return err }
	dst_file.seek(i64(state.copied), .start) or { return err }

	if use_resume && !os.exists(meta_path) {
		os.write_file(tmp_meta_path, json.encode(state)) or {
			return error("Failed to write temporary metadata. Halting.")
		}
		os.mv(tmp_meta_path, meta_path) or {
			return error("Failed to atomically rename metadata. Halting.")
		}
	}

	mut buffer := []u8{len: 1048576}
	mut last_update := time.ticks()
	mut last_meta_write := time.ticks()
	mut unflushed_bytes := u64(0)

	mut interval_ms := i64(sync_interval) * 1000
	if sync_interval < 0 {
		interval_ms = 1000
	}

	for {
		read_bytes := src_file.read(mut buffer) or {
			if err is os.Eof {
				break
			}
			eprintln('\nI/O Error: Read interrupted | Detail: ${err}')
			break
		}
		if read_bytes == 0 {
			break
		}

		mut should_write := true
		if smart_overwrite {
			mut dst_buffer := []u8{len: read_bytes}
			dst_read_bytes := dst_file.read(mut dst_buffer) or { 0 }
			if dst_read_bytes == read_bytes {
				mut matches := true
				for i in 0 .. read_bytes {
					if buffer[i] != dst_buffer[i] {
						matches = false
						break
					}
				}
				if matches {
					should_write = false
				}
			}
			if should_write {
				dst_file.seek(i64(state.copied + unflushed_bytes), .start) or { return err }
			}
		}

		if should_write {
			dst_file.write(buffer[..read_bytes]) or {
				return error("Write failed at byte ${state.copied + unflushed_bytes}. State saved.")
			}
		}

		unflushed_bytes += u64(read_bytes)

		current_ticks := time.ticks()
		if current_ticks - last_meta_write >= interval_ms {
			if unflushed_bytes > 0 {
				dst_file.flush()
				$if windows {
					C._commit(dst_file.fd)
				} $else {
					C.fsync(dst_file.fd)
				}
				state.copied += unflushed_bytes
				if use_resume {
					os.write_file(tmp_meta_path, json.encode(state)) or {
						return error("Failed to write temporary metadata. Halting.")
					}
					os.mv(tmp_meta_path, meta_path) or {
						return error("Failed to atomically rename metadata. Halting.")
					}
				}
				unflushed_bytes = 0
			}
			last_meta_write = current_ticks
		}

		if current_ticks - last_update >= 200 {
			percent := (f64(state.copied + unflushed_bytes) / f64(state.src_size)) * 100.0
			print('\rCopying: ${percent:.2f}% (${state.copied + unflushed_bytes}/${state.src_size} bytes)')
			os.flush()
			last_update = current_ticks
		}
	}

	if unflushed_bytes > 0 {
		dst_file.flush()
		$if windows {
			C._commit(dst_file.fd)
		} $else {
			C.fsync(dst_file.fd)
		}
		state.copied += unflushed_bytes
		if use_resume {
			os.write_file(tmp_meta_path, json.encode(state)) or {
				return error("Failed to write temporary metadata. Halting.")
			}
			os.mv(tmp_meta_path, meta_path) or {
				return error("Failed to atomically rename metadata. Halting.")
			}
		}
	}

	if state.copied == src_size {
		percent := (f64(state.copied) / f64(state.src_size)) * 100.0
		print('\rCopying: ${percent:.2f}% (${state.copied}/${state.src_size} bytes)\n')
		os.flush()

		if use_resume {
			os.rm(meta_path) or {}
		}

		if preserve {
			mtime := os.file_last_mod_unix(src)
			os.utime(dst, mtime, mtime) or {
				eprintln("Warning: Could not preserve timestamp for '${dst}'")
			}
		}
		if verbose {
			println("Completed: '${src}' -> '${dst}'")
		}
	}
}

fn copy_dir(src string, dst string, force bool, interactive bool, preserve bool, verbose bool, size_only bool, sync_interval int, smart_overwrite bool, min_resume_size int) ! {
	if !os.exists(dst) {
		if verbose {
			println("Creating directory: '${dst}'")
		}
		os.mkdir_all(dst) or { return err }
	}

	files := os.ls(src) or { return err }
	for file in files {
		src_child := os.join_path(src, file)
		dst_child := os.join_path(dst, file)

		if os.is_dir(src_child) {
			copy_dir(src_child, dst_child, force, interactive, preserve, verbose, size_only, sync_interval, smart_overwrite, min_resume_size) or { return err }
		} else {
			copy_file(src_child, dst_child, force, interactive, preserve, verbose, size_only, sync_interval, smart_overwrite, min_resume_size) or { return err }
		}
	}

	if preserve {
		mtime := os.file_last_mod_unix(src)
		os.utime(dst, mtime, mtime) or {}
	}
}
