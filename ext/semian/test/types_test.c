#include <stdio.h>
#include <stdlib.h>

#include "types.h"

void assert_equal_int(int actual, int expected, const char *message)
{
  if (actual != expected) {
    fprintf(stderr, "Error: got %d, expected %d (%s)\n", actual, expected, message);
    exit(EXIT_FAILURE);
  }
}

void assert_le_int(int actual, int expected, const char *message)
{
  if (actual > expected) {
    fprintf(stderr, "Error: got %d, which is greater than %d (%s)\n", actual, expected, message);
    exit(EXIT_FAILURE);
  }
}

void test_sliding_window()
{
  semian_simple_sliding_window_shared_t window;
  assert_le_int(sizeof(window), 4096, "window size is greater than a page");
  assert_equal_int(sizeof(window.data), SLIDING_WINDOW_MAX_SIZE * sizeof(int), "window data size");
}

int main(int argc, char **argv)
{
  printf("Info: Running test\n");

  test_sliding_window();

  return EXIT_SUCCESS;
}
