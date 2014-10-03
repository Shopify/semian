require 'mkmf'

if ENV.has_key?('DEBUG')
  $CFLAGS = "-O0 -g"
else
  $CFLAGS = "-O3"
end

abort 'openssl is missing. please install openssl.' unless find_header('openssl/md5.h')
abort 'openssl is missing. please install openssl.' unless find_library('crypto', 'MD5_Init')

have_header 'sys/ipc.h'
have_header 'sys/sem.h'
have_header 'sys/types.h'

have_func 'rb_thread_blocking_region'
have_func 'rb_thread_call_without_gvl'

create_makefile('semian/semian')
