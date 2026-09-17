#include "actuator_command_freshness.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>

#define VG_ACTUATOR_COMMAND_ISSUED_AT_LENGTH 20u

static bool is_digit(char value) {
    return value >= '0' && value <= '9';
}

static bool parse_digits(const char *value, size_t count, int *out) {
    if (!value || !out || count == 0) {
        return false;
    }

    int result = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!is_digit(value[i])) {
            return false;
        }
        result = (result * 10) + (value[i] - '0');
    }
    *out = result;
    return true;
}

static bool is_leap_year(int year) {
    return (year % 4 == 0) && ((year % 100 != 0) || (year % 400 == 0));
}

static int days_in_month(int year, int month) {
    static const int days_by_month[] = {
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    };

    if (month < 1 || month > 12) {
        return 0;
    }
    if (month == 2 && is_leap_year(year)) {
        return 29;
    }
    return days_by_month[month - 1];
}

// Gregorian civil date to days since 1970-01-01. This uses only integer
// arithmetic and is valid for the parser's 0001 through 9999 year range.
static int64_t days_from_civil(int year, int month, int day) {
    year -= month <= 2;
    const int era = year / 400;
    const unsigned year_of_era = (unsigned)(year - (era * 400));
    const unsigned month_prime = (unsigned)(month + (month > 2 ? -3 : 9));
    const unsigned day_of_year = ((153u * month_prime) + 2u) / 5u + (unsigned)day - 1u;
    const unsigned day_of_era = (year_of_era * 365u) + (year_of_era / 4u) -
                                (year_of_era / 100u) + day_of_year;
    return ((int64_t)era * 146097) + (int64_t)day_of_era - 719468;
}

bool vg_actuator_command_parse_issued_at(const char *issued_at, int64_t *epoch_seconds_out) {
    if (!issued_at || !epoch_seconds_out ||
        strlen(issued_at) != VG_ACTUATOR_COMMAND_ISSUED_AT_LENGTH ||
        issued_at[4] != '-' || issued_at[7] != '-' || issued_at[10] != 'T' ||
        issued_at[13] != ':' || issued_at[16] != ':' || issued_at[19] != 'Z') {
        return false;
    }

    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    if (!parse_digits(issued_at, 4, &year) ||
        !parse_digits(issued_at + 5, 2, &month) ||
        !parse_digits(issued_at + 8, 2, &day) ||
        !parse_digits(issued_at + 11, 2, &hour) ||
        !parse_digits(issued_at + 14, 2, &minute) ||
        !parse_digits(issued_at + 17, 2, &second)) {
        return false;
    }

    if (year < 1 || month < 1 || month > 12 || day < 1 || day > days_in_month(year, month) ||
        hour > 23 || minute > 59 || second > 59) {
        return false;
    }

    const int64_t days = days_from_civil(year, month, day);
    *epoch_seconds_out = (days * 86400) + ((int64_t)hour * 3600) +
                         ((int64_t)minute * 60) + second;
    return true;
}

vg_actuator_command_freshness_result_t vg_actuator_command_validate_start_freshness(
    const char *issued_at,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
) {
    if (!trusted_time) {
        return VG_ACTUATOR_COMMAND_FRESHNESS_TIME_NOT_TRUSTED;
    }

    int64_t issued_at_epoch_seconds;
    if (!vg_actuator_command_parse_issued_at(issued_at, &issued_at_epoch_seconds)) {
        return VG_ACTUATOR_COMMAND_FRESHNESS_INVALID_TIMESTAMP;
    }

    if (issued_at_epoch_seconds < trusted_now_epoch_seconds) {
        if (trusted_now_epoch_seconds > INT64_MIN + VG_ACTUATOR_COMMAND_MAX_START_AGE_SECONDS &&
            issued_at_epoch_seconds < trusted_now_epoch_seconds - VG_ACTUATOR_COMMAND_MAX_START_AGE_SECONDS) {
            return VG_ACTUATOR_COMMAND_FRESHNESS_STALE;
        }
    } else if (issued_at_epoch_seconds > trusted_now_epoch_seconds) {
        if (trusted_now_epoch_seconds < INT64_MAX - VG_ACTUATOR_COMMAND_MAX_FUTURE_SKEW_SECONDS &&
            issued_at_epoch_seconds > trusted_now_epoch_seconds + VG_ACTUATOR_COMMAND_MAX_FUTURE_SKEW_SECONDS) {
            return VG_ACTUATOR_COMMAND_FRESHNESS_FUTURE;
        }
    }

    return VG_ACTUATOR_COMMAND_FRESHNESS_FRESH;
}
