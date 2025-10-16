# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../../lib", __FILE__))

require "semian/platform"

unless Semian.sysv_semaphores_supported?
  File.write("Makefile", <<~MAKEFILE)
    all:
    clean:
    install:
  MAKEFILE
  exit
end

require "mkmf"

dir_config("openssl")

abort "openssl is missing. please install openssl." unless find_header("openssl/sha.h")
abort "openssl is missing. please install openssl." unless find_library("crypto", "SHA1")

have_header "sys/ipc.h"
have_header "sys/sem.h"
have_header "sys/types.h"
have_header "sys/shm.h"
have_header "pthread.h"

have_func "rb_thread_blocking_region"
have_func "rb_thread_call_without_gvl"

# Check for pthread library (needed for process-shared mutexes)
have_library("pthread") or abort "pthread library is missing"

$CFLAGS = "-D_GNU_SOURCE -Werror -Wall "
$CFLAGS += if ENV.key?("DEBUG")
  "-O0 -g -DDEBUG"
else
  "-O3"
end

# Add source files for shared PID controller
$srcs = %w[
  semian.c
  resource.c
  sysv_semaphores.c
  tickets.c
  pid_controller_shared.c
  pid_controller_ext.c
]

create_makefile("semian/semian")
