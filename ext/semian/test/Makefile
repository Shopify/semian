# Makefile

CC := gcc -std=gnu99 -I. -I..
TESTS := types_test

all : test

test : types_test

types_test : types_test.c
	$(CC) -o $@ $<
	./$@

clean :
	rm -f *.o
	rm -f $(TESTS)

.PHONY : all test types_test clean
