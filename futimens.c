//
//  futimens.c
//  XcodeClangFormat
//
//  Created by Arnaud Brejeon on 15/09/2017.
//  Copyright © 2017 Mapbox. All rights reserved.
//

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>

int futimens (int fd, const struct timespec tsp[2])
{
    return EBADF;
}
