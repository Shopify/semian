#include <stdlib.h>
#include <stdio.h>

// Include the C source file, so we can access static functions.
#include "../semian.c"

void assert_equal_int(int expected, int actual)
{
  if (expected != actual) {
    printf("Error: %d != %d\n", expected, actual);
    exit(EXIT_FAILURE);
  }
}

void test_force_c_circuits()
{
  setenv("KUBE_HOSTNAME", "machine-1", 1);

  setenv("SEMIAN_CIRCUIT_BREAKER_FORCE_HOST", "machine-2,machine-3", 1);
  assert_equal_int(0, force_c_circuits());

  setenv("SEMIAN_CIRCUIT_BREAKER_FORCE_HOST", "machine-1,machine-2,machine-3", 1);
  assert_equal_int(1, force_c_circuits());
}

int main(int argc, char **argv)
{
  printf("Info: Running Semian test\n");

  // Ruby will replace functions like strdup() with ruby_strdup(), which will
  // segfault if Ruby is not ready. Initialize Ruby so we don't have problems.
  ruby_init();

  test_force_c_circuits();

  return EXIT_SUCCESS;
}
