require 'mkmf'

$CFLAGS = "-O3"

abort 'openssl is missing. please install openssl.' unless find_header('openssl/md5.h')
abort 'openssl is missing. please install openssl.' unless find_library('crypto', 'MD5_Init')

have_func 'rb_thread_blocking_region'
have_func 'rb_thread_call_without_gvl'

create_makefile('semian/semian')
