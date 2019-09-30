;-------------------------------------------------------------------------------
; fatdrvce: Provides MSD and FAT API functions for the TI84+CE calculators.
; Copyright (C) 2019 MateoConLechuga, jacobly0
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU Lesser General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU Lesser General Public License for more details.
;
; You should have received a copy of the GNU Lesser General Public License
; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;-------------------------------------------------------------------------------
; Notes:
; The orginal µCFAT source was used as inspiration for some of the implemented
; file i/o function, and hand-optimized for speed. Some parts of this file are
; related to implementations of functions available in µCFAT. The license for
; µCFAT is provided below.
;-------------------------------------------------------------------------------
; Copyright (c) 2015 Steven Arnow <s@rdw.se>
; 'fat.c' - This file is part of µCFAT
;
; This software is provided 'as-is', without any express or implied
; warranty. In no event will the authors be held liable for any damages
; arising from the use of this software.
;
; Permission is granted to anyone to use this software for any purpose,
; including commercial applications, and to alter it and redistribute it
; freely, subject to the following restrictions:
;
; 	1. The origin of this software must not be misrepresented; you must not
; 	claim that you wrote the original software. If you use this software
; 	in a product, an acknowledgment in the product documentation would be
; 	appreciated but is not required.
;
; 	2. Altered source versions must be plainly marked as such, and must not be
; 	misrepresented as being the original software.
;
; 	3. This notice may not be removed or altered from any source
; 	distribution.
;-------------------------------------------------------------------------------

;-------------------------------------------------------------------------------
fat_Find:
; Locates FAT partitions on the MSD
; Arguments:
;  sp + 3  : msd device structure
;  sp + 6  : storage for found partitions
;  sp + 9  : return number of found partitions
;  sp + 12 : maxium number of partitions to find
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	ld	bc,(iy + 3)			; msd structure
	ld	de,(iy + 6)			; partition pointers
	ld	hl,(iy + 9)			; return number
	ld	a,(iy + 12)			; maximum partitions to locate
	ld	(smc.partitionmsd),bc
	ld	(smc.partitionnumptr),hl
	ld	(smc.partitionptrs),de
	ld	(smc.maxpartitions),a
	xor	a,a
	ld	(hl),a
	sbc	hl,hl
	ld	(scsi.read10.lba),a,hl
	ld	iy,(iy + 3)			; usb device
	call	util_read10			; read zero sector
	ld	hl,FAT_ERROR_USB_FAILED
	ret	nz				; check if error
	ld	hl,(tmp.sectorbuffer)
	ld	de,($90 shl 16) or ($58 shl 8) or ($eb shl 0)
	compare_hl_de				; check if in boot sector
	jq	z,util_one_fat			; sometimes this happens if users are dumb
	ld	(smc.errorsp),sp
	call	util_find
	xor	a,a
	sbc	hl,hl				; return USB_SUCCESS
	ret

;-------------------------------------------------------------------------------
fat_Init:
; Initializes a FAT filesystem from a particular LBA
; Arguments:
;  sp + 3 : Uninitialized FAT structure type
;  sp + 6 : Available FAT partition returned from fat_Find
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	push	ix
	ld	de,(iy + 6)
	ld	iy,(iy + 3)
	ld	(yfatType.partition),de		; store partition pointer
	ld	ix,(yfatType.partition)
	ld	a,hl,(xfatPartition.lba)	; get fat base lba
	ld	(yfatType.fat_base_lba),a,hl
	or	a,a
	sbc	hl,hl
	call	util_read_fat_sector		; read fat zero sector
	jq	nz,.error
	ld	ix,tmp.sectorbuffer
	ld	a,(ix + 12)
	cp	a,(ix + 16)			; ensure 512 byte sectors and 2 FATs
	jq	nz,.error
	ld	a,(ix + 39)
	or	a,a				; can't support reallllly big drives (BPB_FAT32_FATSz32 high)
	jq	nz,.error
	ld	a,(ix + 66)
	cp	a,$28				; check fat32 signature
	jr	z,.goodsig
	cp	a,$29
	jq	nz,.error
.goodsig:
	xor	a,a
	ld	b,a
	ld	hl,(ix + 14)
	ex.s	de,hl
	ld	(yfatType.fat_pos),de
	ld	hl,(ix + 36)			; BPB_FAT32_FATSz32
	ld	(yfatType.fat_size),hl
	add	hl,hl				; * num fats
	adc	a,b
	add	hl,de				; data region
	adc	a,b				; get carry if needed
	ld	(yfatType.data_region),a,hl
	push	af
	ex	de,hl
	ld	a,hl,(ix + 44)			; BPB_FAT32_RootClus
	ld	bc,2
	or	a,a
	sbc	hl,bc
	jr	nc,.nocarry
	dec	a
.nocarry:
	ld	c,(ix + 13)
	ld	(yfatType.cluster_size),c	; sectors per cluster
	jr	.enter
.multiply:
	add	hl,hl
	adc	a,a
.enter:
	rr	c
	jr	nc,.multiply
	pop	bc
	add	hl,de				; bude = data region
	adc	a,b				; root directory location
	ld	(yfatType.root_dir_pos),a,hl
	ld	de,(ix + 48)
	ex.s	de,hl
	ld	(yfatType.fs_info),hl
	xor	a,a
	call	util_read_fat_sector
	jq	nz,.error
	call	util_checkmagic
	jq	nz,.error			; uh oh!
	ld	hl,(ix + 0)			; ix should still point to the temp sector...
	ld	bc,$615252			; don't bother comparing $41 byte...
	xor	a,a
	sbc	hl,bc
	jq	nz,.error
	scf
	sbc	hl,hl
	ex	de,hl
	ld	hl,tmp.sectorbuffer + 488	; invalidate free space
	ld	(hl),de
	inc	hl
	inc	hl
	inc	hl
	ld	(hl),e
	ld	hl,(yfatType.fs_info)		; a is always zero (set from above)
	call	util_write_fat_sector
	jq	nz,.error
	or	a,a
	sbc	hl,hl				; return success
	pop	ix
	ret
.error:
	ld	hl,FAT_ERROR_USB_FAILED
	pop	ix
	ret

;-------------------------------------------------------------------------------
fat_Open:
; Attempts to open a file for reading and/or writing
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Filename (8.3 format)
;  sp + 9 : Open flags
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	ld	de,(iy + 6)
	push	iy
	ld	iy,(iy + 3)
	call	util_locate_entry
	pop	iy
	jq	z,.error
	ld	c,(iy + 9)
	set	BIT_OPEN,c
	ld	iy,(iy + 3)
	push	iy
	push	de
	push	af
	push	hl
	call	util_get_spare_file
	compare_hl_zero
	pop	hl
	pop	af
	pop	de
	jq	z,.errorpop
	ld	(yfatFile.flags),c
	pop	bc
	ld	(yfatFile.fat),bc
	ld	(yfatFile.entry_pointer),de
	ld	(yfatFile.entry_sector),a,hl
	call	util_get_file_first_cluster
	ld	(yfatFile.first_cluster),a,hl
	ld	(yfatFile.current_cluster),a,hl
	compare_auhl_zero
	jr	nz,.notempty
.empty:
	bit	BIT_WRITE,c
	jr	z,.cantalloc
	push	iy
	call	util_alloc_cluster
	pop	iy
	compare_auhl_zero
	jq	nz,.allocedclusted
	ld	(yfatFile.flags),a
	jq	.error
.allocedclusted:
	ld	(yfatFile.first_cluster),a,hl
	ld	(yfatFile.current_cluster),a,hl
.cantalloc:
	xor	a,a
	sbc	hl,hl
	jq	.storesize
.notempty:
	call	util_get_file_size
.storesize:
	call	util_set_file_size
	ld	a,hl,(yfatFile.current_cluster)
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_cluster_to_sector
	pop	iy
	ld	(yfatFile.current_sector),a,hl
	xor	a,a
	sbc	hl,hl
	ld	(yfatFile.cluster_sector),a
	ld	(yfatFile.fpossector),hl
	lea	hl,iy
	ret
.errorpop:
	pop	hl
.error:
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
fat_SetSize:
; Sets the size of the file
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
;  sp + 9 : Size low
;  sp + 12 : Size high byte
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	ld	de,(iy + 6)
	push	iy
	ld	iy,(iy + 3)
	call	util_locate_entry
	ld	(yfatType.working_sector),a,hl
	ld	(yfatType.working_pointer),de
	ld	(util_update_file_sizes.sectorlow),hl
	ld	(util_update_file_sizes.sectorhigh),a
	push	de
	pop	iy
	ld	a,(iy + 20 + 1)			; start at first cluster, and walk the chain
	ld	hl,(iy + 20 - 2)		; until the number of clusters is allocated
	ld	l,(iy + 26 + 0)
	ld	h,(iy + 26 + 1)
	ld	(.currentcluster),a,hl
	pop	iy
	ld	bc,(iy + 9)			; get new file size
	ld	a,(iy + 12)
	jq	z,.invalidpath			; check if real file
	push	iy
	ld	iy,(iy + 3)
	push	iy
	ld	iy,(yfatType.working_pointer)
	ld	e,hl,(iy + 28)
	ld	(iy + 28),a,bc			; otherwise, directly store new size
	pop	iy
	ld	(yfatType.working_size),a,bc
	pop	iy				; get current file size
	call	__lcmpu
	jq	z,.success			; if same size, just return
	jq	c,.makelarger
.makesmaller:
	call	.writeentry
	compare_hl_zero
	jq	nz,.notzerofile
	push	iy
	ld	iy,(iy + 3)
	jq	.dealloc
.notzerofile:
	push	hl
	pop	bc
	ld	a,hl,(.currentcluster)
	compare_auhl_zero
	jq	z,.success
	push	iy
	ld	iy,(iy + 3)
	dec	bc
	jq	.entertraverseclusters
.traverseclusters:
	push	bc
	call	util_next_cluster
	compare_auhl_zero
	pop	bc
	jq	z,.failedchain			; the filesystem is screwed up
	dec	bc
.entertraverseclusters:
	compare_bc_zero
	jq	nz,.traverseclusters
	call	util_set_new_eoc_cluster	; mark this cluster as unused
.dealloc:
	call	util_dealloc_cluster_chain	; deallocate all other clusters
	pop	iy
	jq	nz,.usberror
	jq	.success
.makelarger:
	call	.writeentry			; get number of clusters there needs to be
	compare_hl_zero
	jq	z,.success
.allocateclusters:
	push	hl
	push	iy
	ld	iy,(iy + 3)
	ld	a,hl,(.currentcluster)
	ld	(yfatType.working_cluster),a,hl
	call	util_next_cluster
	compare_auhl_zero
	jq	nz,.alreadyallocated
	call	util_alloc_cluster
.alreadyallocated:
	ld	(.currentcluster),a,hl
	compare_auhl_zero
	pop	iy
	pop	hl
	jq	z,.failedalloc
	dec	hl
	compare_hl_zero
	jq	nz,.allocateclusters
	jq	.success
.writeentry:
	push	iy
	ld	iy,(iy + 3)
	ld	a,hl,(yfatType.working_size)
	compare_auhl_zero
	jq	nz,.writenotzero
	push	ix
	ld	ix,(yfatType.working_pointer)
	xor	a,a
	ld	(ix + 20 + 0),a			; remove first cluster if zero
	ld	(ix + 20 + 1),a
	ld	(ix + 26 + 0),a
	ld	(ix + 26 + 1),a
	pop	ix
.writenotzero:
	ld	a,hl,(yfatType.working_sector)
	call	util_write_fat_sector		; write the new size
	jq	z,.writegood
	pop	iy
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	ret
.writegood:
	call	util_update_file_sizes		; update any file pointers as needed!
	ld	a,hl,(yfatType.working_size)
	call	util_ceil_byte_size_to_cluster_size
	pop	iy
	ret
.success:
	xor	a,a
	sbc	hl,hl
	ret
.failedchain:
	ld	hl,FAT_ERROR_CLUSTER_CHAIN
	ret
.invalidpath:
	ld	hl,FAT_ERROR_INVALID_PATH
	ret
.failedalloc:
	ld	hl,FAT_ERROR_FAILED_ALLOC
	ret
.currentcluster:
	rd	0

;-------------------------------------------------------------------------------
fat_GetSize:
; Gets the size of the file
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
; Returns:
;  File size in bytes
	ld	iy,0
	add	iy,sp
	ld	de,(iy + 6)
	ld	iy,(iy + 3)
	call	util_locate_entry
	jq	z,.invalidpath
	push	de
	pop	iy
	ld	a,hl,(iy + 28)
	ret
.invalidpath:
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
fat_SetFilePos:
; Sets the offset sector position in the file
; Arguments:
;  sp + 3 : FAT File structure type
;  sp + 6 : Sector offsets
; Returns:
;  FAT_SUCCESS on success
	pop	hl,iy,de
	push	de,iy,hl
	ld	(yfatFile.fpossector),de
	ld	hl,(yfatFile.file_size_sectors)
	compare_hl_de
	jq	c,.eof
	ex	de,hl		; determine cluster offset
	ld	bc,0
	push	iy
	ld	iy,(yfatFile.fat)
	ld	c,(yfatType.cluster_size)
	xor	a,a
	ld	e,a
	push	bc,hl
	call	__lremu		; get sector offset in cluster
	ld	(.clusteroffset),hl
	pop	hl,bc
	xor	a,a
	ld	e,a
	call	__ldivu
	pop	iy
	push	hl
	pop	bc
	ld	a,hl,(yfatFile.first_cluster)
	ld	(yfatFile.current_cluster),a,hl
.getclusterpos:
	push	bc
	ld	a,hl,(yfatFile.current_cluster)
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_next_cluster
	pop	iy
	ld	(yfatFile.current_cluster),a,hl
	pop	bc
	compare_hl_zero
	jq	z,.chainfailed
	dec	bc
	compare_bc_zero
	jr	nz,.getclusterpos
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_cluster_to_sector
	pop	iy
	ld	de,0
.clusteroffset := $-3
	add	hl,de
	adc	a,0
	ld	(yfatFile.current_sector),a,hl
.success:
	xor	a,a
	sbc	hl,hl
	ret
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	ret
.eof:
	ld	hl,FAT_ERROR_EOF
	ret
.chainfailed:
	ld	hl,FAT_ERROR_CLUSTER_CHAIN
	ret


;-------------------------------------------------------------------------------
fat_GetFilePos:
; Gets the offset position in the file
; Arguments:
;  sp + 3 : FAT File structure type
; Returns:
;  Position in file
	pop	de
	ex	hl,(sp)
	push	de
	call	util_valid_file_ptr
	ret	z
	ld	hl,(yfatFile.fpossector)
	ret

;-------------------------------------------------------------------------------
fat_SetAttrib:
; Sets the attributes of the path
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
;  sp + 9 : File attributes byte
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	ld	de,(iy + 6)
	push	iy
	ld	iy,(iy + 3)
	call	util_locate_entry
	pop	iy
	jq	z,.invalidpath
	push	hl,af
	ld	a,(iy + 9)
	push	de
	pop	iy
	ld	(iy + 11),a
	pop	af,hl
	call	util_write_fat_sector
	jq	nz,.usberror
	xor	a,a
	sbc	hl,hl
	ret
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	ret
.invalidpath:
	ld	hl,FAT_ERROR_INVALID_PATH
	ret

;-------------------------------------------------------------------------------
fat_GetAttrib:
; Gets the attributes of the path
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
; Returns:
;  File attribute byte
	ld	iy,0
	add	iy,sp
	ld	de,(iy + 6)
	ld	iy,(iy + 3)
	call	util_locate_entry
	jq	z,.invalidpath
	push	de
	pop	iy
	ld	a,(iy + 11)
	ret
.invalidpath:
	ld	hl,FAT_ERROR_INVALID_PATH
	ret

;-------------------------------------------------------------------------------
fat_Close:
; Closes an open file handle, freeing it for future use
; Arguments:
;  sp + 3 : FAT File structure type
; Returns:
;  FAT_SUCCESS on success
	pop	de
	ex	hl,(sp)
	push	de
	call	util_valid_file_ptr
	jr	z,.error
	;res	BIT_OPEN,(yfatFile.flags)
	xor	a,a
	ld	(yfatFile.flags),a
	sbc	hl,hl
	ret
.error:
	ld	hl,FAT_ERROR_INVALID_PARAM
	ret

;-------------------------------------------------------------------------------
fat_ReadSector:
; Reads a sector from an open file handle
; Arguments:
;  sp + 3 : FAT File structure type
;  sp + 6 : Buffer to read into
; Returns:
;  FAT_SUCCESS on success
	pop	de,iy,hl
	push	hl,iy,de
	ld	(yfatFile.working_buffer),hl
	ld	de,(yfatFile.fpossector)
	ld	hl,(yfatFile.file_size_sectors)
	compare_hl_de
	jq	z,.eof
	ld	a,hl,(yfatFile.current_sector)
	ld	bc,0
	ld	c,(yfatFile.cluster_sector)
	add	hl,bc
	adc	a,b
	push	hl
	push	af
	push	iy
	ld	iy,(yfatFile.fat)
	ld	a,(yfatType.cluster_size)
	cp	a,c
	pop	iy
	inc	c
	jr	nz,.readsector
	ld	a,hl,(yfatFile.current_cluster)
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_next_cluster
	pop	iy
	ld	(yfatFile.current_cluster),a,hl
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_cluster_to_sector
	pop	iy
	ld	(yfatFile.current_sector),a,hl
	ld	c,0
.readsector:
	ld	hl,(yfatFile.working_buffer)
	ld	(util_read10.buffer),hl
	ld	(yfatFile.cluster_sector),c
	ld	hl,(yfatFile.fpossector)
	inc	hl
	ld	(yfatFile.fpossector),hl
	ld	iy,(yfatFile.fat)
	pop	af
	pop	hl
	call	util_read_fat_sector
	jq	nz,.usberror
	xor	a,a
	sbc	hl,hl
	jq	.restorebuffer
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	jq	.restorebuffer
.invalidcluster:
	ld	hl,FAT_ERROR_INVALID_CLUSTER
	jq	.restorebuffer
.restorebuffer:
	ld	bc,tmp.sectorbuffer
	ld	(util_read10.buffer),bc
	ret
.eof:
	ld	hl,FAT_ERROR_EOF
	ret

;-------------------------------------------------------------------------------
fat_WriteSector:
; Writes a sector to an open file handle
; Arguments:
;  sp + 3 : FAT File structure type
;  sp + 6 : Buffer to write
; Returns:
;  FAT_SUCCESS on success
	pop	de,iy,hl
	push	hl,iy,de
	ld	(yfatFile.working_buffer),hl
	ld	de,(yfatFile.fpossector)
	ld	hl,(yfatFile.file_size_sectors)
	compare_hl_de
	jq	z,.eof
	ld	a,hl,(yfatFile.current_sector)
	ld	bc,0
	ld	c,(yfatFile.cluster_sector)
	add	hl,bc
	adc	a,b
	push	hl
	push	af
	push	iy
	ld	iy,(yfatFile.fat)
	ld	a,(yfatType.cluster_size)
	cp	a,c
	pop	iy
	inc	c
	jr	nz,.writesector
	ld	a,hl,(yfatFile.current_cluster)
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_next_cluster
	pop	iy
	ld	(yfatFile.current_cluster),a,hl
	push	iy
	ld	iy,(yfatFile.fat)
	call	util_cluster_to_sector
	pop	iy
	ld	(yfatFile.current_sector),a,hl
	ld	c,0
.writesector:
	ld	hl,(yfatFile.working_buffer)
	ld	(util_write10.buffer),hl
	ld	(yfatFile.cluster_sector),c
	ld	hl,(yfatFile.fpossector)
	inc	hl
	ld	(yfatFile.fpossector),hl
	ld	iy,(yfatFile.fat)
	pop	af
	pop	hl
	call	util_write_fat_sector
	jq	nz,.usberror
	xor	a,a
	sbc	hl,hl
	jq	.restorebuffer
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	jq	.restorebuffer
.invalidcluster:
	ld	hl,FAT_ERROR_INVALID_CLUSTER
	jq	.restorebuffer
.restorebuffer:
	ld	bc,tmp.sectorbuffer
	ld	(util_write10.buffer),bc
	ret
.eof:
	ld	hl,FAT_ERROR_EOF
	ret

;-------------------------------------------------------------------------------
fat_Create:
; Creates a new file or directory entry
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
;  sp + 9 : New name
;  sp + 12 : File attributes
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	ld	hl,-512
	add	hl,sp
	ld	sp,hl			; temporary space for concat
	ex	de,hl
	push	de
	ld	hl,(iy + 6)
	call	_StrCopy
	ld	hl,(iy + 9)
	call	_StrCopy
	pop	de
	push	iy
	ld	iy,(iy + 3)
	call	util_locate_entry
	pop	iy
	jq	nz,.alreadyexists
	ld	hl,(iy + 6)
	inc	hl			; todo: check for '/' or '.'?
	ld	a,(hl)
	or	a,a
	jq	nz,.notroot
	push	iy
	ld	iy,(iy + 3)
	push	iy
	call	util_alloc_entry_root
	pop	iy
	ld	(yfatType.working_pointer),de
	ld	(yfatType.working_sector),a,hl
	pop	iy
	jq	.createfile
.notroot:
	ld	de,(iy + 6)
	push	iy
	ld	iy,(iy + 3)
	call	util_locate_entry
	pop	iy
	jq	z,.invalidpath
	push	iy
	ld	iy,(iy + 3)
	ld	(yfatType.working_pointer),de
	ld	(yfatType.working_sector),a,hl
	ld	iy,tmp.sectorbuffer
	ld	a,(iy + 20 + 1)
	ld	hl,(iy + 20 - 2)	; get hlu
	ld	l,(iy + 26 + 0)
	ld	h,(iy + 26 + 1)		; get the entry's cluster
	pop	iy
	push	iy
	ld	iy,(iy + 3)
	ld	(yfatType.working_cluster),a,hl
	call	util_alloc_entry
	pop	iy
.createfile:
	compare_auhl_zero
	jq	z,.failedalloc
	push	ix
	push	iy
	ld	de,(iy + 9)
	ld	iy,(iy + 3)
	ld	(yfatType.working_sector),a,hl
	ld	hl,(yfatType.working_pointer)
	push	hl
	call	util_get_fat_name
	pop	ix
	pop	iy
	ld	a,(iy + 12)
	ld	(ix + 11),a
	xor	a,a
	sbc	hl,hl
	ld	(ix + 28),a,hl		; set initial size to zero
	pop	ix
	ld	iy,(iy + 3)
	ld	a,hl,(yfatType.working_sector)
	call	util_write_fat_sector
	jq	nz,.usberror

	; todo: create . and .. directories if a directory

	ld	e,FAT_SUCCESS
	jq	.restorestack
.failedalloc:
	ld	e,FAT_ERROR_FAILED_ALLOC
	jq	.restorestack
.alreadyexists:
	ld	e,FAT_ERROR_EXISTS
	jq	.restorestack
.invalidpath:
	ld	e,FAT_ERROR_INVALID_PATH
	jq	.restorestack
.usberror:
	ld	e,FAT_ERROR_USB_FAILED
	jq	.restorestack
.restorestack:
	ld	hl,512
	ld	d,l
	add	hl,sp
	ld	sp,hl
	ex.s	de,hl
	ret

;-------------------------------------------------------------------------------
fat_Delete:
; Deletes a file and deallocates the spaced used by it on disk
; Arguments:
;  sp + 3 : FAT structure type
;  sp + 6 : Path
; Returns:
;  FAT_SUCCESS on success
	ld	iy,0
	add	iy,sp
	push	ix
	call	.enter
	pop	ix
	ret
.enter:
	ld	de,(iy + 6)
	ld	iy,(iy + 3)
	push	iy
	call	util_locate_entry
	pop	iy
	jq	z,.invalidpath
	push	de
	pop	ix
	ld	a,(ix + 11)
	bit	4,a
	jq	z,.normalfile
.directory:

	; todo: handle directory deletion
	; need to check if empty first

	ld	hl,FAT_ERROR_NOT_SUPPORTED
	ret

.normalfile:
	ld	(ix + 11),0
	ld	(ix + 0),$e5
	push	ix
	call	util_write_fat_sector
	pop	ix
	ld	a,(ix + 20 + 1)
	ld	hl,(ix + 20 - 2)	; get hlu
	ld	l,(ix + 26 + 0)
	ld	h,(ix + 26 + 1)
	call	util_dealloc_cluster_chain
	jq	nz,.usberror
	ret
.invalidpath:
	ld	hl,FAT_ERROR_INVALID_PATH
	ret
.usberror:
	ld	hl,FAT_ERROR_USB_FAILED
	ret

;-------------------------------------------------------------------------------
util_end_of_chain:
; inputs
;   auhl: cluster
; outputs
;   flag c set if end of cluster chain
; perserves
;   hl, af, bc, de
	push	de,hl,af
	ex	de,hl
	and	a,$0f
	ld	hl,8
	add	hl,de
	ex	de,hl
	adc	a,$f0
	pop	de,hl
	ld	a,d
	pop	de
	ret

;-------------------------------------------------------------------------------
util_set_new_eoc_cluster:
; inputs
;   iy: fat structure
;   auhl: cluster entry to mark as end
; outputs:
;   auhl: previous contents of cluster entry
	compare_auhl_zero
	ret	z
	call	util_end_of_chain
	ret	c
	push	af,hl
	call	util_cluster_entry_to_sector
	call	util_read_fat_sector
	pop	hl,de
	ld	a,d
	jq	nz,.error
	call	util_get_cluster_offset
	ld	a,$ff			; mark new end of chain
	ld	bc,(hl)
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	d,(hl)			; dubc = previous cluster
	ld	(hl),$0f		; end of chain marker
	push	bc,de
	pop	af,hl
	ret
.error:
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
;   auhl: starting cluster to deallocate from
; outputs:
;   yfatType.working_cluster: ending cluster
;   yfatType.working_sector: sector with cluster offset
util_dealloc_cluster_chain:
	compare_auhl_zero
	jq	z,.success
	call	util_end_of_chain
	jq	c,.success
	ld	(yfatType.working_cluster),a,hl
	call	util_cluster_entry_to_sector
	ld	(yfatType.working_sector),a,hl
	call	util_read_fat_sector
	jq	nz,.error
.followchain:
	ld	a,hl,(yfatType.working_cluster)
	call	util_get_cluster_offset
	xor	a,a
	ld	bc,(hl)
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	d,(hl)			; dubc = previous cluster
	ld	(hl),a			; zero previous cluster
	push	bc,de
	pop	af,hl			; auhl = previous cluster
	ld	(yfatType.working_cluster),a,hl
	call	util_end_of_chain	; check if end of chain
	jq	c,.updatepartialchain
	compare_auhl_zero
	jq	z,.updatepartialchain
	call	util_cluster_entry_to_sector
	ld	e,a
	ld	a,bc,(yfatType.working_sector)
	call	__lcmpu
	jq	z,.followchain
	jq	.updatepartialchain
.updatepartialchain:
	ld	a,hl,(yfatType.working_sector)
	call	util_update_fat_table
	ld	a,hl,(yfatType.working_cluster)
	jq	z,util_dealloc_cluster_chain
	jq	.error
.error:
	xor	a,a
	inc	a
	ret
.success:
	xor	a,a
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
;   iy + working_cluster: previous cluster
;   iy + working_sector: entry sector
;   iy + working_pointer: entry in sector
util_alloc_cluster:
	xor	a,a
	sbc	hl,hl
.traversefat:
	push	hl,af
	ld	bc,(yfatType.fat_pos)
	add	hl,bc
	adc	a,0
	call	util_read_fat_sector
	jq	z,.readfatsector
	pop	af,hl
	jq	.usberror
.readfatsector:
	push	ix
	ld	ix,tmp.sectorbuffer - 4
	ld	b,128
.traverseclusterchain:
	lea	ix,ix + 4
	ld	a,hl,(ix)
	compare_auhl_zero
	jr	z,.unallocatedcluster
	djnz	.traverseclusterchain
	pop	ix
	pop	af,hl
	jq	.traversefat
	ret
.unallocatedcluster:
	ld	a,128
	sub	a,b
	ld	bc,0
	ld	c,a
	lea	de,ix
	ld	a,$0f
	scf
	sbc	hl,hl
	ld	(ix),a,hl
	pop	ix,af,hl
	push	af,hl
	call	util_auhl_shl7
	add	hl,bc
	adc	a,b			; new cluster
	ld	(yfatType.working_next_cluster),a,hl
	pop	hl,af
	ld	bc,(yfatType.fat_pos)
	add	hl,bc
	adc	a,0
	call	util_update_fat_table
	jq	nz,.usberror
	ld	a,hl,(yfatType.working_cluster)
	compare_auhl_zero
	jq	z,.linkentrytofirstcluster
.linkclusterchain:
	push	hl
	call	util_cluster_entry_to_sector
	push	hl,af
	call	util_read_fat_sector
	pop	de,bc,hl
	jq	nz,.usberror
	push	bc,de
	call	util_get_cluster_offset
	push	ix
	push	hl
	pop	ix
	ld	a,hl,(yfatType.working_next_cluster)
	ld	(ix),a,hl
	pop	ix,af,hl
	call	util_update_fat_table
	jq	nz,.usberror
	ld	a,hl,(yfatType.working_cluster)
	compare_auhl_zero
	jq	nz,.nolinkneeded
.linkentrytofirstcluster:
	ld	a,hl,(yfatType.working_sector)
	call	util_read_fat_sector
	jq	nz,.usberror
	push	ix
	ld	ix,(yfatType.working_pointer)
	ld	de,(yfatType.working_next_cluster + 0)
	ld	(ix + 26),e
	ld	(ix + 27),d
	ld	de,(yfatType.working_next_cluster + 2)
	ld	(ix + 20),e
	ld	(ix + 21),d
	pop	ix
	ld	a,hl,(yfatType.working_sector)
	call	util_write_fat_sector
	jq	nz,.usberror
.nolinkneeded:
	ld	a,hl,(yfatType.working_next_cluster)
	ret
.usberror:
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
;   auhl: sector to update in FAT
util_update_fat_table:
	push	af,hl
	call	util_write_fat_sector
	pop	hl,de
	ld	a,d
	ret	nz
	ld	bc,(yfatType.fat_size)
	add	hl,bc
	adc	a,0
	call	util_write_fat_sector
	ret	nz
	xor	a,a
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
;   iy + working_cluster: previous cluster
;   iy + working_sector: entry sector
;   iy + working_pointer: entry in sector
; outputs:
;   auhl: new entry sector
;   de: offset in entry sector
util_do_alloc_entry:
	call	util_alloc_cluster
	call	util_cluster_to_sector
	ld	b,0
	push	ix
	ld	ix,tmp.sectorbuffer
	ld	(ix + 0),$e5
	ld	(ix + 11),b
	ld	(ix + 32),b
	ld	(ix + 43),b
	pop	ix
	push	hl,af
	call	util_write_fat_sector
	jq	nz,.error
	pop	af,hl
	ret
.error:
	pop	hl,hl
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
;   iy + working_cluster: first cluster
;   iy + working_sector: parent entry sector
;   iy + working_pointer: parent entry in sector
; outputs:
;   auhl: new entry sector
;   de: offset in entry sector
util_alloc_entry:
	ld	a,hl,(yfatType.working_cluster)
	call	util_cluster_to_sector
	compare_auhl_zero
	jq	nz,.validcluster
	call	util_do_alloc_entry
	ld	de,0
	ret
.validcluster:
	ld	b,(yfatType.cluster_size)
.loop:
	push	bc,hl,af
	call	util_read_fat_sector
	push	iy
	ld	iy,tmp.sectorbuffer - 32
	ld	b,16
.findavailentry:
	lea	iy,iy + 32
	ld	a,(iy + 0)
	cp	a,$e5			; deleted entry, let's use it!
	jr	z,.foundavailentry
	or	a,a
	jq	z,.foundendoflist	; end of list, let's allocate here
	djnz	.findavailentry
	pop	iy,af,hl
	call	util_increment_auhl
	pop	bc
	djnz	.loop
.movetonextcluster:
	ld	a,hl,(yfatType.working_cluster)
	call	util_next_cluster
	compare_auhl_zero
	jq	nz,.nextclusterisvalid
	push	af,hl
	ld	a,hl,(yfatType.working_cluster)
	call	util_do_alloc_entry
	ld	de,0
	ret
.nextclusterisvalid:
	ld	(yfatType.working_cluster),a,hl
	jq	util_alloc_entry
.foundavailentry:
	lea	de,iy			; pointer to new entry
	pop	iy,af,hl,bc		; auhl = sector with entry
	ret
.foundendoflist:
	dec	b
	jq	z,.movetonextcluster
	lea	de,iy			; pointer to new entry
	xor	a,a
	ld	(iy + 0),a
	ld	(iy + 11),a
	pop	iy,af,hl,bc
	push	af,hl,de
	call	util_increment_auhl
	call	util_write_fat_sector
	pop	de,hl
	jq	nz,.usberr
	pop	af
	ret
.usberr:
	pop	hl
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
; inputs:
;   iy: fat structure
; outputs:
;   auhl: new entry sector
;   de: offset in entry sector
util_alloc_entry_root:
	xor	a,a
	sbc	hl,hl
	ld	(yfatType.working_sector),a,hl
	ld	(yfatType.working_pointer),hl
	ld	a,hl,(yfatType.root_dir_pos)
	call	util_sector_to_cluster
	ld	(yfatType.working_cluster),a,hl
	jq	util_alloc_entry

;-------------------------------------------------------------------------------
util_valid_file_ptr:
	compare_hl_zero
	jr	z,.invalid
	push	hl
	pop	iy
	bit	BIT_OPEN,(yfatFile.flags)
	ret	nz
.invalid:
	xor	a,a
	sbc	hl,hl
	ld	e,a
	ret

;-------------------------------------------------------------------------------
util_get_spare_file:
; outputs
;  b: index of file (if needed?)
;  hl, iy: pointer to file index
	ld	b,MAX_FAT_FILES
	ld	iy,fatFile4
.find:
	bit	BIT_OPEN,(yfatFile.flags)
	ret	z
	lea	iy,iy - sizeof fatFile
	djnz	.find
	xor	a,a
	sbc	hl,hl				; return null
	ret

;-------------------------------------------------------------------------------
util_get_file_first_cluster:
	push	iy
	ld	iy,(yfatFile.entry_pointer)
	ld	a,(iy + 20 + 1)
	ld	hl,(iy + 20 - 2)
	ld	l,(iy + 26 + 0)
	ld	h,(iy + 26 + 1)		; first cluster
	pop	iy
	ret

;-------------------------------------------------------------------------------
util_get_file_size:
	push	iy
	ld	iy,(yfatFile.entry_pointer)
	ld	a,hl,(iy + 28)
	pop	iy
	ret

;-------------------------------------------------------------------------------
util_set_file_size:
	ld	(yfatFile.file_size),a,hl
	call	util_ceil_byte_size_to_sector_size
	ld	(yfatFile.file_size_sectors),a,hl
	ret

;-------------------------------------------------------------------------------
util_get_fat_name:
; convert name to storage name (covers most cases)
; inputs
;   de: name
;   hl: <output> name (11+1 bytes)
	push	de
	ld	b,0
.loop1:
	ld	a,b
	cp	a,8
	jr	nc,.done1
	ld	a,(de)
	cp	a,'.'
	jr	z,.done1
	cp	a,'/'
	jr	z,.done1
	or	a,a
	jr	z,.done1
	ld	(hl),a
	inc	de
	inc	hl
	inc	b
	jr	.loop1
.done1:
	ld	a,b
	cp	a,8
	jr	nc,.elseif
	ld	a,(de)
	or	a,a
	jr	z,.elseif
	cp	a,'/'
	jr	z,.elseif
	ld	a,8
.loop2:
	cp	a,b
	jr	z,.fillremaining
	ld	(hl),' '
	inc	hl
	inc	b
	jr	.loop2
.fillremaining:
	inc	de
.loop3456:
	ld	a,b
	cp	a,11
	jq	nc,.return
	ld	a,(de)
	or	a,a
	jr	z,.other
	cp	a,'/'
	jr	z,.other
	inc	de
.store:
	ld	(hl),a
	inc	hl
	inc	b
	jr	.loop3456
.other:
	ld	a,' '
	jr	.store
.elseif:
	ld	a,b
	cp	a,8
	jr	nz,.spacefill
	ld	a,(de)
	cp	a,'.'
	jr	nz,.spacefill
	jr	.fillremaining
.spacefill:
	ld	a,11
.spacefillloop:
	cp	a,b
	jq	z,.return
	ld	(hl),' '
	inc	hl
	inc	b
	jq	.spacefillloop
.return:
	pop	de
	ret

;-------------------------------------------------------------------------------
util_get_component_start:
	ld	a,(de)
	or	a,a
	ret	z
	cp	a,'/'
	ret	nz
	inc	de
	jq	util_get_component_start

;-------------------------------------------------------------------------------
util_get_next_component:
	ld	a,(de)
	or	a,a
	ret	z
	cp	a,'/'
	ret	z
	inc	de
	jq	util_get_next_component

;-------------------------------------------------------------------------------
util_is_directory_empty:
; inputs
;   iy: FAT structure
;   auhl: cluster
; outputs
;   z flag set if directory is empty
.enter:
	ld	(yfatType.working_cluster),a,hl
	call	util_cluster_to_sector
	compare_auhl_zero
	ret	z
	ld	(yfatType.working_sector),a,hl
	ld	b,(ufatType.cluster_size)
.next_sector:
	push	bc
	ld	a,hl(yfatType.working_sector)
	call	util_read_fat_sector
	jq	nz,.fail
	push	ix
	ld	b,16
	ld	ix,tmp.sectorbuffer - 32
.loop:
	lea	ix,ix + 32
	ld	a,(ix + 11)
	cp	a,$0f
	jr	z,.next
	ld	a,(ix + 0)
	or	a,a
	jq	z,.successpop
	cp	a,$e5
	jr	z,.next
	cp	a,'.'
	jr	z,.next
	cp	a,' '
	jr	z,.next
	jq	.failpop
.next:
	djnz	.loop
	ld	a,hl(yfatType.working_sector)
	call	util_increment_auhl
	ld	(yfatType.working_sector),a,hl
	pop	bc
	djnz	.next_sector
	ld	a,hl(yfatType.working_cluster)
	call	util_next_cluster
	jq	.enter
.successpop:
	pop	bc,bc
.success:
	xor	a,a
	ret
.failpop:
	pop	bc,bc
.fail:
	xor	a,a
	inc	a
	ret

;-------------------------------------------------------------------------------
util_update_file_sizes:
	ld	de,(yfatType.working_pointer)
	ld	a,hl,(yfatType.working_size)
	push	iy
	ld	b,MAX_FAT_FILES
	ld	iy,fatFile4
.find:
	bit	BIT_OPEN,(yfatFile.flags)
	jr	z,.next
	push	hl
	ld	hl,(yfatFile.entry_pointer)
	compare_hl_de
	pop	hl
	jr	nz,.next
	push	hl
	ld	a,hl,(yfatFile.entry_sector)
	ld	c,0
.sectorlow := $-1
	ld	de,0
.sectorhigh := $-1
	compare_hl_de
	pop	hl
	jr	nz,.next
	cp	a,c
	jr	nz,.next
	ld	(yfatFile.file_size),a,hl
.next:
	lea	iy,iy - sizeof fatFile
	djnz	.find
	pop	iy
	ret

;-------------------------------------------------------------------------------
util_locate_entry:
; finds the component entry
; inputs
;   iy: fat structure
;   de: name
; outputs
;   hl: sector of entry
;   de: offset to entry in sector
;   z set if not found
	ld	a,hl,(yfatType.root_dir_pos)
	ld	(yfatType.working_sector),a,hl
	ld	(yfatType.working_pointer),de
.findcomponent:
	ld	de,(yfatType.working_pointer)
	call	util_get_component_start
	jq	z,.error
	ld	hl,tmp.string
	call	util_get_fat_name
	call	util_get_next_component
	ld	(yfatType.working_pointer),de
.locateloop:
	ld	a,hl,(yfatType.working_sector)
	call	util_read_fat_sector
	jq	nz,.error
	push	iy
	ld	iy,tmp.sectorbuffer - 32
	ld	c,16
.detectname:
	lea	iy,iy + 32
	ld	a,(iy + 11)
	and	a,$0f
	cp	a,$0f			; long file name entry, skip
	jr	z,.detectname
	ld	a,(iy + 0)
	cp	a,$e5			; deleted entry, skip
	jr	z,.detectname
	or	a,a
	jq	z,.errorpopiy		; end of list, suitable entry not found
	lea	de,iy
	ld	hl,tmp.string
	ld	b,11
.cmpnames:
	ld	a,(de)
	cp	a,(hl)
	jr	nz,.cmpfail
	inc	de
	inc	hl
	djnz	.cmpnames
	lea	de,iy
	pop	iy
	ld	hl,(yfatType.working_pointer)
	ld	a,(hl)
	or	a,a			; check if end of component lookup (de)
	jq	z,.foundlastcomponent
	push	iy
	push	de
	pop	iy
	ld	a,(iy + 20 + 1)
	ld	hl,(iy + 20 - 2)	; get hlu
	ld	l,(iy + 26 + 0)
	ld	h,(iy + 26 + 1)		; get the entry's cluster, and convert it to the sector
	pop	iy
	call	util_cluster_to_sector
	compare_auhl_zero
	jq	z,.error		; this means it is empty... which shouldn't happen!
	ld	(yfatType.working_sector),a,hl
	jq	.findcomponent		; found the component we were looking for (yay)
.cmpfail:
	dec	c
	jr	nz,.detectname
	pop	iy
.movetonextsector:
	ld	a,hl,(yfatType.working_sector)
	call	util_sector_to_cluster
	push	hl,af
	ld	a,hl,(yfatType.working_sector)
	ld	bc,1
	add	hl,bc
	add	a,b
	call	util_sector_to_cluster
	pop	bc,de
	compare_hl_de
	jr	nz,.movetonextcluster
	cp	a,b
	jr	nz,.movetonextcluster
	ld	a,hl,(yfatType.working_sector)
	ld	bc,1
	add	hl,bc
	adc	a,b
	jq	.storesectorandloop
.movetonextcluster:
	ld	a,hl,(yfatType.working_sector)
	call	util_sector_to_cluster
	call	util_next_cluster
	call	util_cluster_to_sector
.storesectorandloop:
	ld	(yfatType.working_sector),a,hl
	compare_auhl_zero
	jq	nz,.locateloop		; make sure we can get the next cluster
.errorpopiy:
	pop	iy
.error:
	xor	a,a
	sbc	hl,hl
	ret
.foundlastcomponent:
	ld	a,hl,(yfatType.working_sector)
	compare_auhl_zero
	ret

;-------------------------------------------------------------------------------
util_cluster_to_sector:
; gets the base sector of the cluster
; inputs
;   auhl = cluster
;   iy -> fat structure
; outputs
;   auhl = sector
	ld	de,-2
	add	hl,de
	adc	a,d
	ld	c,a
	ld	a,(yfatType.cluster_size)
	jr	c,.enter
	xor	a,a
	sbc	hl,hl
	ret
.loop:
	add	hl,hl
	rl	c
.enter:
	rrca
	jr	nc,.loop
	ld	a,de,(yfatType.data_region)
	add	hl,de
	adc	a,c
	ret

;-------------------------------------------------------------------------------
util_sector_to_cluster:
; gets sector to base cluster
; inputs
;   auhl = sector
;   iy -> fat structure
; outputs
;   auhl = cluster
	compare_auhl_zero
	ret	z
	ld	bc,(yfatType.data_region + 0)
	or	a,a
	sbc	hl,bc
	sbc	a,(yfatType.data_region + 3)
	ld	de,(yfatType.cluster_size - 2)
	ld	d,0
	ld	e,a
.loop:
	add	hl,hl
	ex	de,hl
	adc	hl,hl
	ex	de,hl
	jr	nc,.loop
	ld	a,d
	push	de
	push	hl
	inc	sp
	pop	hl
	inc	sp
	inc	sp
	ld	bc,2
	add	hl,bc
	adc	a,b
	ret

;-------------------------------------------------------------------------------
util_next_cluster:
; moves to next cluster in the chain
; inputs
;   auhl = parent cluster
;   iy -> fat structure
; outputs
;   auhl = next cluster
	ld	de,0
	add	hl,hl
	adc	a,a		; << 1
	ld	e,l		; cluster pos
	push	af		; >> 8
	inc	sp
	push	hl
	inc	sp
	pop	hl
	inc	sp
	xor	a,a
	ld	bc,(yfatType.fat_pos)
	add	hl,bc
	adc	a,a
	push	de
	call	util_read_fat_sector
	pop	hl
	jr	nz,.error
	add	hl,hl
	ld	de,tmp.sectorbuffer
	add	hl,de
	ld	de,(hl)
	inc	hl
	inc	hl
	inc	hl
	ld	a,(hl)
	and	a,$0f
	ld	hl,8
	add	hl,de
	ex	de,hl
	ld	e,a
	adc	a,$f0
	jr	nc,.found
	ld	e,a
	ex	de,hl
	ret
.found:
	ld	a,e
	ret
.error:
	xor	a,a
	sbc	hl,hl
	ret

;-------------------------------------------------------------------------------
util_read_fat_sector:
; inputs
;  auhl: LBA address
;  iy: fat_t structure
; outputs
;  de: read sector
	ld	e,bc,(yfatType.fat_base_lba)
	add	hl,bc
	adc	a,e			; big endian
	ld	de,scsi.read10.lba
	ld	(de),a
	dec	sp
	push	hl
	inc	sp
	pop	af			; hlu
	inc	de
	ld	(de),a
	ld	a,h
	inc	de
	ld	(de),a
	ld	a,l
	inc	de
	ld	(de),a
	push	iy
	ld	iy,(yfatType.partition)
	ld	iy,(yfatPartition.msd)
	call	util_read10
	pop	iy
	ret

;-------------------------------------------------------------------------------
util_write_fat_sector:
; inputs
;  auhl: lba address
;  iy: fat_t structure
; outputs
	ld	e,bc,(yfatType.fat_base_lba)
	add	hl,bc
	adc	a,e			; big endian
	ld	de,scsi.write10.lba
	ld	(de),a
	dec	sp
	push	hl
	inc	sp
	pop	af			; hlu
	inc	de
	ld	(de),a
	ld	a,h
	inc	de
	ld	(de),a
	ld	a,l
	inc	de
	ld	(de),a
	push	iy
	ld	iy,(yfatType.partition)
	ld	iy,(yfatPartition.msd)
	call	util_write10
	pop	iy
	ret

;-------------------------------------------------------------------------------
util_read10:
	ld	de,tmp.sectorbuffer
.buffer := $-3
	ld	hl,scsi.read10
	jq	util_scsi_request

;-------------------------------------------------------------------------------
util_write10:
	ld	de,tmp.sectorbuffer
.buffer := $-3
	ld	hl,scsi.write10
	jq	util_scsi_request

;-------------------------------------------------------------------------------
util_find:
	call	util_read10			; read sector
	jr	nz,.error
	call	util_checkmagic
	ret	nz
	ld	hl,-64
	add	hl,sp
	ld	sp,hl
	ex	de,hl
	ld	hl,tmp.sectorbuffer + 446 + 4
	ld	bc,64
	ldir					; copy the current partition table to the stack
	xor	a,a
	sbc	hl,hl
	add	hl,sp
	ld	a,4
.loop:
	push	af
	push	hl
	ld	a,(hl)
	cp	a,$0c				; fat32 partition? (lba)
	call	z,util_fat32_found
	cp	a,$0b				; fat32 partition? (chs)
	call	z,util_fat32_chs_found
	cp	a,$0f				; extended partition? (lba)
	call	z,util_ebr_found
	cp	a,$05				; extended partition? (chs)
	call	z,util_ebr_chs_found
	pop	hl
	ld	bc,16
	add	hl,bc
	pop	af
	dec	a
	jr	nz,.loop
	ld	hl,64
	add	hl,sp
	ld	sp,hl
	ret
.error:
	ld	sp,0
smc.errorsp := $ - 3
	ld	hl,FAT_ERROR_USB_FAILED
	ret

;-------------------------------------------------------------------------------
util_one_fat:
	call	util_checkmagic
	ld	hl,0
smc.partitionnumptr := $ - 3
	ld	(hl),0
	ret	nz
	ld	(hl),1
	ld	hl,(smc.partitionptrs)
	ld	de,0
	ld	(hl),de
	inc	hl
	ld	(hl),e				; lba
	inc	hl
	inc	hl
	inc	hl
	ld	bc,0
smc.partitionmsd := $ - 3
	ld	(hl),bc				; msd
	ex	de,hl				; return USB_SUCCESS
	ret

;-------------------------------------------------------------------------------
util_fat32_chs_found:
	jq	util_fat32_found

;-------------------------------------------------------------------------------
util_fat32_found:
	push	af
	ld	bc,(smc.partitionnumptr)
	ld	a,(bc)
	cp	a,0
smc.maxpartitions := $ - 1
	jr	z,.found_max
	ld	bc,4				; hl -> start of lba
	add	hl,bc
	push	hl
	ld	de,0
smc.partitionptrs := $ - 3
	ld	bc,4
	ldir					; copy lba
	ld	(smc.partitionptrs),de
	ex	de,hl
	ld	bc,(smc.partitionmsd)
	ld	(hl),bc
	pop	hl
	ld	de,scsi.read10.lba + 3
	call	util_reverse_copy		; move to next read sector

	ld	hl,(smc.partitionnumptr)
	inc	(hl)
.found_max:
	pop	af
	ret

;-------------------------------------------------------------------------------
util_ebr_chs_found:
	jq	util_ebr_found

;-------------------------------------------------------------------------------
util_ebr_found:
	push	af
	ld	bc,4				; hl -> start of lba
	add	hl,bc
	ld	de,scsi.read10.lba + 3
	call	util_reverse_copy
	call	util_find			; recursively locate fat32 partitions
	pop	af
	ret

;-------------------------------------------------------------------------------
util_reverse_copy:
	ld	b,4
.copy:
	ld	a,(hl)
	ld	(de),a
	inc	hl
	dec	de
	djnz	.copy
	ret

;-------------------------------------------------------------------------------
util_checkmagic:
	ld	hl,tmp.sectorbuffer + 510	; offset = signature
util_sector_checkmagic:
	ld	a,(hl)
	cp	a,$55
	ret	nz
	inc	hl
	ld	a,(hl)
	cp	a,$aa
	ret

;-------------------------------------------------------------------------------
util_increment_auhl:
	ld	bc,1
	add	hl,bc
	adc	a,b
	ret

;-------------------------------------------------------------------------------
util_auhl_shl7:
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	add	hl,hl
	adc	a,a
	ret

;-------------------------------------------------------------------------------
util_get_cluster_offset:
	ld	a,l
	and	a,$7f
	or	a,a
	sbc	hl,hl
	ld	l,a
	add	hl,hl
	add	hl,hl
	ld	de,tmp.sectorbuffer
	add	hl,de
	ret

;-------------------------------------------------------------------------------
util_cluster_entry_to_sector:
	ld	e,a
	xor	a,a
	ld	bc,128
	call	__ldivu
	ld	bc,(yfatType.fat_pos)
	add	hl,bc
	adc	a,e
	ret

;-------------------------------------------------------------------------------
util_ceil_byte_size_to_sector_size:
	compare_auhl_zero
	ret	z
	ld	e,a
	push	hl,de
	xor	a,a
	ld	bc,512
	push	bc
	call	__lremu
	compare_hl_zero
	pop	bc,de,hl
	push	af
	xor	a,a
	call	__ldivu
	pop	af
	ret	z
	inc	hl
	ret

;-------------------------------------------------------------------------------
util_ceil_byte_size_to_cluster_size:
	compare_auhl_zero
	ret	z
	push	af,hl
	xor	a,a
	sbc	hl,hl
	ld	h,(yfatType.cluster_size)
	add	hl,hl
	push	hl
	pop	bc
	pop	hl,de
	ld	e,d
	push	hl,de,bc
	call	__lremu
	compare_hl_zero
	pop	bc,de,hl
	push	af
	xor	a,a
	call	__ldivu
	pop	af
	ret	z
	inc	hl
	ret

;-------------------------------------------------------------------------------
util_compare_auhl_zero:
	compare_hl_zero
	ret	nz
	or	a,a
	ret
