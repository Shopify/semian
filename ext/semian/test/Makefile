# Makefile

# 'gcc -I. -I/usr/local/include/ruby-2.6.0/x86_64-linux -I/usr/local/include/ruby-2.6.0/ruby/backward \
# -I/usr/local/include/ruby-2.6.0 -I../../../../ext/semian \
# -DHAVE_SYS_IPC_H -DHAVE_SYS_SEM_H -DHAVE_SYS_TYPES_H -DHAVE_RB_THREAD_CALL_WITHOUT_GVL \
# -fPIC -D_GNU_SOURCE -Werror -Wall -std=gnu99 -O3  -o semian.o -c ../../../../ext/semian/semian.c

CC := gcc
LIBRARIES := ruby c m crypto
WARNINGS := error all
DEFINES := HAVE_SYS_IPC_H HAVE_SYS_SEM_H HAVE_SYS_TYPES_H HAVE_RB_THREAD_CALL_WITHOUT_GVL DEBUG _GNU_SOURCE
INCLUDES := . /usr/local/include/ruby-2.6.0/ruby/backward /usr/local/include/ruby-2.6.0 /usr/local/include/ruby-2.6.0 /usr/local/include/ruby-2.6.0/x86_64-linux
CFLAGS := $(patsubst %,-l%,$(LIBRARIES)) $(patsubst %,-W%,$(WARNINGS)) $(patsubst %,-D%,$(DEFINES)) $(patsubst %,-I%,$(INCLUDES)) -std=gnu99 -O0 -g
ROOTDIR := /workspace
OBJDIR := $(ROOTDIR)/tmp/x86_64-linux/semian/2.6.3
OBJS := $(wildcard $(OBJDIR)/*.o)
TESTS := semian_test

all : $(TESTS)

%_test.o : %_test.c $(filter-out $(OBJDIR)/semian.o,$(OBJS))
	$(CC) -o $@ $^ $(CFLAGS)

%_test : %_test.o
	echo "Info: Running $@"
	./$<

clean :
	rm -f *.o

.SECONDARY : $(patsubst %,%.o,$(TESTS))
.PHONY : all clean
