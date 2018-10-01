.intel_syntax noprefix

# System V calling convention cheatsheet
# Params: rdi, rsi, rdx, rcx, r8, r9, xmm0-7
# Return: rax (int 64 bits), rax:rdx (int 128 bits), xmm0 (float)
# Callee cleanup: rbx, rbp, r12-15
# Scratch: rax, rdi, rsi, rdx, rcx, r8, r9, r10, r11 

.section .rodata
  leaf_fmt:   .string "%2$c: %1$d\n"
  branch_fmt: .string "BR: %d\n"
  text:       .string "bibbity bobbity"

  .equ bitstr_length,    32
  .equ bitstr_size,      40
  .equ codebook_size,    256 * bitstr_size

  .equ tree_left,        0
  .equ tree_right,       8
  .equ tree_count,       16
  .equ tree_value,       20
  .equ tree_size,        24

  .equ heap_len,         0
  .equ heap_data,        4
  .equ heap_size,        512 * 8 + 16 # 512 ptrs + 4 byte length + 12 byte padding
  .equ counts_size,      256 * 4

.section .text
  .global main
  .extern printf, calloc, malloc, memset, puts

main:
  push   r12
  push   r13
  sub    rsp, codebook_size

  mov    rdi, OFFSET text
  call   generate_tree
  mov    r12, rax
  
  mov    rdi, rsp
  mov    rsi, r12
  call   generate_codebook

  mov    rdi, rsp
  call   print_codebook

  mov    rdi, r12
  call   free_tree


  add    rsp, codebook_size
  pop    r13
  pop    r12

  xor    rax, rax
  ret

# rdi - The starting address of the codebook we want to generate
# rsi - Huffman-tree root (ptr)
generate_codebook:
  sub    rsp, bitstr_size
  xorps  xmm0, xmm0                           # Create a 0-initialized bitstring. This will be
  movups XMMWORD PTR [rsp], xmm0              # used in the recursive function calls
  movups XMMWORD PTR [rsp + 16], xmm0
  mov    QWORD PTR [rsp + 32], 0
  mov    rdx, rsp
  call   generate_codebook_recurse
  add    rsp, bitstr_size
  ret

# rdi - The codebook's starting address
# rsi - The current Huffman-tree node
# rdx - The bitstring used for code generation
generate_codebook_recurse:
  push   rbp
  push   r12
  push   r13
  test   rdi, rdi                             # If we reached a null pointer we're done 
  jz     generate_codebook_recurse_done
  mov    r12, rsi
  cmp    QWORD PTR [r12 + tree_left], 0       # If at least one of the children is not null
  jnz    generate_codebook_branch             # then we need to treat the current node as a branch
  cmp    QWORD PTR [r12 + tree_right], 0
  jnz    generate_codebook_branch
  mov    r8d, DWORD PTR [r12 + tree_value]    # Get the value of the current node
  movups xmm0, XMMWORD PTR [rdx]              # Get the values of the current bitstring into some registers
  movups xmm1, XMMWORD PTR [rdx + 16]
  mov    r9, QWORD PTR [rdx + 32]
  lea    rax, [r8 + 4*r8]                     # The index calculation needs to add 40 * index. With lea arithmetic this can be represented as
  lea    r10, [rdi + 4*rax]                   # base address + 4 * (5 * index). This is done in two lea instructions
  movups XMMWORD PTR [r10], xmm0              # And copy the data over to it
  movups XMMWORD PTR [r10 + 16], xmm1
  mov    QWORD PTR [r10 + 32], r9
  jmp    generate_codebook_recurse_done
generate_codebook_branch:
  # First, calculate the necessary indices and bitmask to use for the bitstring
  mov    r13, QWORD PTR [rdx + bitstr_length] # Load the current length of the bitstring
  mov    rcx, r13                             # This will be used to index into the bitstring data. We'll need two copies for it
  shr    r13, 6                               # We first get which 64 bit chunk of the bitstring we want to modify
  and    rcx, 63                              # Then the bit we want to change
  mov    rbp, 1                               # Generate the mask we'll use to set the correct bit
  shl    rbp, cl
  # We'll start with the right branch
  or     QWORD PTR [rdx + 8*r13], rbp         # Set the bit
  inc    QWORD PTR [rdx + bitstr_length]      # Increase the bitstring length
  mov    rsi, QWORD PTR [r12 + tree_right]
  call   generate_codebook_recurse
  # Now we move on to the left branch: rbx - left child, r13 - bitstring index, rbp - mask
  not    rbp
  and    QWORD PTR [rdx + 8*r13], rbp
  mov    rsi, QWORD PTR [r12 + tree_left]
  call   generate_codebook_recurse
  dec    QWORD PTR [rdx + bitstr_length]      # Decrease the bitstring length
generate_codebook_recurse_done:
  pop    r13
  pop    r12
  pop    rbp
  ret

# rdi - text
# RET rax - Huffman-tree root (ptr)
generate_tree:
  push   r12
  push   r13
  sub    rsp, 4176                            # 1024 bytes for the char counts, 4 bytes for heap length, 4096 bytes for the heap, 12 byte padding
  mov    r12, rdi                             # Save the original text so it doesn't get clobbered
  mov    rdi, rsp                             # Zero out the character counts and the heap length
  xor    rsi, rsi
  mov    rdx, 1040
  call   memset
  xor    rax, rax
generate_tree_count_chars:
  mov    al, BYTE PTR [r12]
  test   al, al
  jz     generate_tree_construct_heap
  inc    DWORD PTR [rsp + 4*rax]
  inc    r12
  jmp    generate_tree_count_chars
generate_tree_construct_heap:
  xorps  xmm0, xmm0                           # Generate the zeroed heap
  movaps XMMWORD PTR [rsp], xmm0
  mov    r12, 255                             # The loop counter
  cmp    r12, 0                               # Check if we reached zero (on subsequent iterations "dec" sets the correct flag)
generate_tree_leaves:
  jl     generate_tree_branches               # If not then it's time to generate the branches
  mov    r13d, DWORD PTR [rsp + 4*r12]        # Load the count at the ith position
  test   r13d, r13d                           # And check if it's zero
  jz     generate_tree_leaves_counters        # If it is we can skip this iteration
  mov    rdi, 1                               # If not, we need to allocate a new leaf node
  mov    rsi, tree_size                     
  call   calloc
  mov    DWORD PTR [rax + tree_value], r12d   # Save the value and the count to the tree
  mov    DWORD PTR [rax + tree_count], r13d
  lea    rdi, [rsp + counts_size]             # Then push it onto the heap
  mov    rsi, rax
  call   heap_push
generate_tree_leaves_counters:
  dec    r12                                  # Decrement the loop counter and start over
  jmp    generate_tree_leaves
generate_tree_branches:
  cmp    DWORD PTR [rsp + counts_size], 1     # Check if there are still at least two elements in the heap
  jle    generate_tree_done                   # If not, we're done
  lea    rdi, [rsp + counts_size]             # Get the left child
  call   heap_pop
  mov    r12, rax
  lea    rdi, [rsp + counts_size]             # Get the right child
  call   heap_pop
  mov    r13, rax
  mov    rdi, tree_size                       # Create the new tree node, the pointer to it will be in rax
  call   malloc
  mov    ecx, DWORD PTR [r12 + tree_count]    # The new node's count: left count + right count
  add    ecx, DWORD PTR [r13 + tree_count]
  mov    QWORD PTR [rax + tree_left], r12     # Save the new node's fields: left, right, count (leave value unititialized, it shouldn't be used with branch nodes)
  mov    QWORD PTR [rax + tree_right], r13
  mov    DWORD PTR [rax + tree_count], ecx
  lea    rdi, [rsp + counts_size]             # Add the branch to the heap
  mov    rsi, rax
  call   heap_push
  jmp    generate_tree_branches
generate_tree_done:
  lea    rdi, [rsp + counts_size]             # The tree's root will be in rax after the pop
  call   heap_pop
  add    rsp, 4176
  pop    r13
  pop    r12
  ret

# rdi - heap ptr
# rsi - tree ptr
heap_push:
  lea    rax, QWORD PTR [rdi + heap_data]     # We load the heap's data ptr and length to the respective registers
  mov    ecx, DWORD PTR [rdi + heap_len]      # Load the current length
  lea    edx, [ecx + 1]                       # First, calculate the new length (length + 1)
  mov    DWORD PTR [rdi + heap_len], edx      # Then save it
  mov    QWORD PTR [rax + 8*rcx], rsi         # And finally add the new value at the end of the array
heap_push_sift_up:
  test   rcx, rcx                             # Test if we got to the root (index == 0)
  jz     heap_push_done
  lea    rdx, [rcx - 1]                       # Calculate the parent index: (index - 1) / 2
  shr    rdx, 1
  lea    r8, [rax + 8*rcx]                    # Get the pointer to the current and parent elements
  lea    r9, [rax + 8*rdx]              
  mov    r10, QWORD PTR [r8]                  # Load the current and the parent elements
  mov    r11, QWORD PTR [r9]                            
  mov    esi, DWORD PTR [r10 + tree_count]    # Load the current tree's count
  cmp    DWORD PTR [r11 + tree_count], esi    # If parent count <= current count
  jle    heap_push_done                       # Then we're done
  mov    QWORD PTR [r8], r11                  # Otherwise swap the two elements
  mov    QWORD PTR [r9], r10 
  mov    rcx, rdx
  jmp    heap_push_sift_up
heap_push_done:
  ret

# rdi - heap ptr
# RET rax - tree ptr
heap_pop:
  mov    r8d, DWORD PTR [rdi + heap_len]      # Load the heap's length 
  test   r8d, r8d                             # If it's 0 then the heap's empty
  jz     heap_empty
  lea    rdx, [rdi + heap_data]               # Get the heap's data ptr
  mov    rax, QWORD PTR [rdx]                 # The return value will be the tree's current root
  lea    r8d, [r8d - 1]                       # Calculate the new length
  mov    DWORD PTR [rdi + heap_len], r8d      # And save it
  mov    rsi, QWORD PTR [rdx + 8*r8]          # Load the element we're going to swap with the root
  mov    QWORD PTR [rdx], rsi                 # Swap the root and the last element
  mov    QWORD PTR [rdx + 8*r8], rax
  xor    r9, r9                               # The loop index
heap_pop_sift_down:
  mov    rcx, r9                              # Save the target index at the start of the loop
  lea    r10, [r9 + r9 + 1]                   # The left child index
  lea    r11, [r9 + r9 + 2]                   # The right child index
  cmp    r10, r8
  jge    heap_pop_check_right
  mov    rdi, QWORD PTR [rdx + 8*r10]         # Load the left child
  mov    rsi, QWORD PTR [rdx + 8*rcx]         # Load the target     
  mov    esi, DWORD PTR [rsi + tree_count]    # Load the target tree count
  cmp    DWORD PTR [rdi + tree_count], esi    # If the left tree count < target tree count
  jge    heap_pop_check_right
  mov    rcx, r10
heap_pop_check_right:
  cmp    r11, r8
  jge    heap_pop_compare_indices
  mov    rdi, QWORD PTR [rdx + 8*r11]         # Load the right child
  mov    rsi, QWORD PTR [rdx + 8*rcx]         # Load the target     
  mov    esi, DWORD PTR [rsi + tree_count]    # Load the target tree count
  cmp    DWORD PTR [rdi + tree_count], esi    # If the right tree count < target tree count
  jge    heap_pop_compare_indices
  mov    rcx, r11
heap_pop_compare_indices:
  cmp    r9, rcx                              # If the target index == current index we're done
  je     heap_pop_done
  mov    rdi, QWORD PTR [rdx + 8*r9]          # Otherwise we swap the values
  mov    rsi, QWORD PTR [rdx + 8*rcx]
  mov    QWORD PTR [rdx + 8*r9], rsi
  mov    QWORD PTR [rdx + 8*rcx], rdi
  mov    r9, rcx
  jmp    heap_pop_sift_down
heap_pop_done:
  ret
heap_empty:
  xor    rax, rax                             # Return a null pointer to indicate the heap was empty
  ret

# rdi - tree ptr
print_tree:
  push   rbx                                
  mov    rbx, rdi                             # Save the parameter in a register we can reuse during recursion
print_tree_main:                              # Printing the right subtree is a tail call so we need a label after the setup part
  mov    rdi, QWORD PTR [rbx + tree_left]     # Check if the left branch is null
  test   rdi, rdi
  jz     print_tree_leaf                      # If it is then it _might_ be a leaf, jump to that part
  call   print_tree                           # If it is not, print it
  jmp    print_tree_branch                    # At this point we know we're not printing a leaf
print_tree_leaf:
  mov    rdi, OFFSET leaf_fmt                 # Load the format string for leaves
  cmp    QWORD PTR [rbx + tree_right], 0      # Check if the node is actually a leaf
  jz     print_tree_current                   # And if it is, keep the leaf format string
print_tree_branch:
  mov    rdi, OFFSET branch_fmt
print_tree_current:
  mov    esi, DWORD PTR [rbx + tree_count]    # Print the current node
  mov    edx, DWORD PTR [rbx + tree_value]
  xor    rax, rax
  call   printf
  mov    rbx, [rbx + tree_right]              # Load the right child
  test   rbx, rbx
  jnz    print_tree_main                      # And if it's not null, print it
  pop    rbx
  ret

# rdi - codebook start ptr
print_codebook:
  push   rbx
  push   r12
  sub    rsp, 48                              # The bitstring we're going to print
  mov    r12, rdi
  xor    rbx, rbx                             # Save the loop counter into a register that doesn't get clobbered
print_codebook_loop:
  cmp    rbx, 255
  jg     print_codebook_done
  lea    rax, [rbx + 4*rbx]                   # We get the codebook entry at the specific index   
  lea    r10, [r12 + 4*rax] 
  mov    rdx, QWORD PTR [r10 + bitstr_length] # Load the length of the bitstring
  test   rdx, rdx                             # If it's zero then the codepoint didn't exist in the original alphabet, skip
  jz     print_codebook_counters
print_codebook_char:
  mov    BYTE PTR [rsp], bl                   # First, the character we're printing the code for
  mov    WORD PTR [rsp + 1], 0x203a           # Then ": "
  mov    WORD PTR [rsp + rdx + 3], 0x0a00     # At the end, add a newline and the null terminator
print_codebook_generate_binary:
  dec    rdx
  jl     print_codebook_binary
  mov    r9, rdx                              # Two copies of the loop counter
  mov    rcx, rdx
  shr    r9, 6                                # Calculate the bitstring part we're going to load
  and    rcx, 63                              # The bit we're interested in
  mov    rsi, QWORD PTR [r10 + r9]            # One of the 4, 64 bit parts of the bitstring we're going to print
  shr    rsi, cl                              # Get the relevant bit into the 0th position
  and    rsi, 1                               # Mask the rest of the bits
  add    rsi, '0'                             # Convert it to ASCII
  mov    BYTE PTR [rsp + rdx + 3], sil        # And copy it into the string
  jmp    print_codebook_generate_binary
print_codebook_binary:
  mov    rdi, rsp                             # Print the current bitstring
  call   puts
print_codebook_counters:
  inc    rbx                                  # And go to the next codebook entry
  jmp    print_codebook_loop
print_codebook_done:
  add    rsp, 48
  pop    r12
  pop    rbx
  ret

# rdi - tree ptr
free_tree:
  push   rbx
  mov    rbx, rdi
  test   rbx, rbx                             # When the tree ptr we're trying to free is already null we reached the termination condition
  jz     free_tree_done
  mov    rdi, [rbx + tree_left]               # Otherwise free the left child first
  call   free_tree
  mov    rdi, [rbx + tree_right]              # Then the right child
  call   free_tree
  mov    rdi, rbx                             # And finally, the node itself
  call   free
free_tree_done:
  pop    rbx
  ret
