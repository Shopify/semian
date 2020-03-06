$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)

require 'semian/platform'

unless Semian.sysv_semaphores_supported?
  File.write "Makefile", <<MAKEFILE
all:
clean:
install:
MAKEFILE
  exit
end

require 'mkmf'

abort 'openssl is missing. please install openssl.' unless find_header('openssl/sha.h')
abort 'openssl is missing. please install openssl.' unless find_library('crypto', 'SHA1')

have_header 'sys/ipc.h'
have_header 'sys/sem.h'
have_header 'sys/types.h'

have_func 'rb_thread_blocking_region'
have_func 'rb_thread_call_without_gvl'

$CFLAGS = "-D_GNU_SOURCE -Werror -Wall "
if ENV.key?('DEBUG')
  $CFLAGS << "-O0 -g -DDEBUG"
else
  $CFLAGS << "-O3"
end

$LDFLAGS << "-Wl,--allow-multiple-definition"

create_makefile('semian/semian')
