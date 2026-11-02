#pragma once
#include <malloc/malloc.h>
#include <stdlib.h>
#define malloc_usable_size(p) malloc_size(p)
