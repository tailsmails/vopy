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
	fp.version('1.0.0')
	fp.description('Resumable bit-by-bit file copy with checksum integrity.')
	fp.skip_executable()

	recursive := fp.bool('recursive', `r`, false, 'Copy directories recursively')
	force := fp.bool('force', `f`, false, 'Force overwrite, skip previous resume metadata')
	interactive := fp.bool('interactive', `i`, false, 'Prompt before overwriting/resuming')
	no_preserve := fp.bool('no-preserve', `n`, false, 'Do not preserve file modification time (mtime)')
	verbose := fp.bool('verbose', `v`, false, 'Explain what is being done')
	size_only := fp.bool('size-only', `s`, false, 'Skip files if size matches, ignoring modification time')

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
		if os.is_dir(dst) {
			final_dst = os.join_path(dst, os.file_name(src))
		}
		copy_dir(src, final_dst, force, interactive, preserve, verbose, size_only) or {
			eprintln('Directory copy error: ${err}')
			exit(1)
		}
	} else {
		mut final_dst := dst
		if os.is_dir(dst) {
			final_dst = os.join_path(dst, os.file_name(src))
		}
		copy_file(src, final_dst, force, interactive, preserve, verbose, size_only) or {
			eprintln('File copy error: ${err}')
			exit(1)
		}
	}
}

fn copy_file(src string, dst string, force bool, interactive bool, preserve bool, verbose bool, size_only bool) ! {
	if !os.exists(src) {
		return error("Source file '${src}' does not exist.")
	}

	meta_path := dst + '.resume'
	tmp_meta_path := meta_path + '.tmp'
	src_size := os.file_size(src)

	if os.exists(dst) && !force {
		if os.file_size(dst) == src_size && !os.exists(meta_path) {
			if size_only || os.file_last_mod_unix(src) == os.file_last_mod_unix(dst) {
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

	if os.exists(meta_path) {
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

	if !os.exists(dst) {
		mut f := os.create(dst) or { return err }
		f.close()
	}

	mut src_file := os.open(src) or { return err }
	defer { src_file.close() }

	mut dst_file := os.open_file(dst, 'r+', 0o666) or { return err }
	defer { dst_file.close() }

	src_file.seek(i64(state.copied), .start) or { return err }
	dst_file.seek(i64(state.copied), .start) or { return err }

	mut buffer := []u8{len: 65536}
	mut last_update := time.ticks()

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

		dst_file.write(buffer[..read_bytes]) or {
			return error("Write failed at byte ${state.copied}. State saved.")
		}
		dst_file.flush()

		$if windows {
			C._commit(dst_file.fd)
		} $else {
			C.fsync(dst_file.fd)
		}

		state.copied += u64(read_bytes)

		os.write_file(tmp_meta_path, json.encode(state)) or {
			return error("Failed to write temporary metadata. Halting.")
		}
		os.mv(tmp_meta_path, meta_path) or {
			return error("Failed to atomically rename metadata. Halting.")
		}

		current_ticks := time.ticks()
		if current_ticks - last_update >= 200 {
			percent := (f64(state.copied) / f64(state.src_size)) * 100.0
			print('\rCopying: ${percent:.2f}% (${state.copied}/${state.src_size} bytes)')
			os.flush()
			last_update = current_ticks
		}
	}

	if state.copied == src_size {
		percent := (f64(state.copied) / f64(state.src_size)) * 100.0
		print('\rCopying: ${percent:.2f}% (${state.copied}/${state.src_size} bytes)\n')
		os.flush()

		if verbose {
			println("Verifying integrity of '${dst}'...")
		}

		is_valid := verify_files(src, dst) or {
			return error("Integrity check failed: could not read files during validation.")
		}

		if !is_valid {
			return error("Integrity check failed: source and destination files do not match.")
		}

		os.rm(meta_path) or {}

		if preserve {
			mtime := os.file_last_mod_unix(src)
			os.utime(dst, mtime, mtime) or {
				eprintln("Warning: Could not preserve timestamp for '${dst}'")
			}
		}
		if verbose {
			println("Completed and verified: '${src}' -> '${dst}'")
		}
	}
}

fn verify_files(src string, dst string) !bool {
	mut src_file := os.open(src) or { return err }
	defer { src_file.close() }

	mut dst_file := os.open(dst) or { return err }
	defer { dst_file.close() }

	mut src_buf := []u8{len: 65536}
	mut dst_buf := []u8{len: 65536}

	for {
		src_read := src_file.read(mut src_buf) or {
			if err is os.Eof {
				dst_read := dst_file.read(mut dst_buf) or {
					if err is os.Eof {
						return true
					}
					return false
				}
				if dst_read > 0 {
					return false
				}
				return true
			}
			return err
		}

		dst_read := dst_file.read(mut dst_buf) or {
			return false
		}

		if src_read != dst_read {
			return false
		}

		if src_read == 0 {
			break
		}

		if src_buf[..src_read] != dst_buf[..dst_read] {
			return false
		}
	}
	return true
}

fn copy_dir(src string, dst string, force bool, interactive bool, preserve bool, verbose bool, size_only bool) ! {
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
			copy_dir(src_child, dst_child, force, interactive, preserve, verbose, size_only) or { return err }
		} else {
			copy_file(src_child, dst_child, force, interactive, preserve, verbose, size_only) or { return err }
		}
	}

	if preserve {
		mtime := os.file_last_mod_unix(src)
		os.utime(dst, mtime, mtime) or {}
	}
}
