#include "util.h"

const char* check_id_arg(VALUE id)
{
  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING) {
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }

  const char *c_id_str = NULL;
  if (TYPE(id) == T_SYMBOL) {
    c_id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    c_id_str = RSTRING_PTR(id);
  }

  return c_id_str;
}

key_t generate_key(const char *name)
{
  char semset_size_key[128];
  char *uniq_id_str;

  // It is necessary for the cardinatily of the semaphore set to be part of the key
  // or else sem_get will complain that we have requested an incorrect number of sems
  // for the desired key, and have changed the number of semaphores for a given key
  const int NUM_SEMAPHORES = 4;
  sprintf(semset_size_key, "_NUM_SEMS_%d", NUM_SEMAPHORES);
  uniq_id_str = malloc(strlen(name) + strlen(semset_size_key) + 1);
  strcpy(uniq_id_str, name);
  strcat(uniq_id_str, semset_size_key);

  union {
    unsigned char str[SHA_DIGEST_LENGTH];
    key_t key;
  } digest;
  SHA1((const unsigned char *) uniq_id_str, strlen(uniq_id_str), digest.str);
  free(uniq_id_str);
  /* TODO: compile-time assertion that sizeof(key_t) > SHA_DIGEST_LENGTH */
  return digest.key;
}

const char* to_s(VALUE obj) {
  if (RB_TYPE_P(obj, T_STRING)) {
    return RSTRING_PTR(obj);
  } else if (RB_TYPE_P(obj, T_SYMBOL)) {
    return rb_id2name(SYM2ID(obj));
  }

  rb_raise(rb_eArgError, "could not convert object to string");
  return NULL;
}
