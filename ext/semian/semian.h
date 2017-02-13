/*
System, 3rd party, and project includes

Implements Init_semian, which is used as C/Ruby entrypoint.
*/

#ifndef SEMIAN_H
#define SEMIAN_H

// System includes
#include <errno.h>
#include <string.h>
#include <stdio.h>

// 3rd party includes
#include <openssl/sha.h>
#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

//semian includes
#include "resource.h"

void Init_semian();

#endif //SEMIAN_H
