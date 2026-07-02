#!/bin/sh

# SPDX-License-Identifier: MPL-2.0

LTP_DIR=$(dirname "$0")
TEST_TMP_DIR=${CONFORMANCE_TEST_WORKDIR:-/tmp}
LOG_FILE=$TEST_TMP_DIR/result.log
JSON_REPORT=$TEST_TMP_DIR/result.json
RUNTEST_BACKUP=$TEST_TMP_DIR/syscalls.all
RESULT=0

export LTP_TIMEOUT_MUL=5
export LTPROOT=$LTP_DIR
export TMPDIR=$TEST_TMP_DIR
export LTP_COLORIZE_OUTPUT=0
export KCONFIG_SKIP_CHECK=1

rm -f $LOG_FILE $JSON_REPORT $RUNTEST_BACKUP
KIRK_ARGS="--run-suite syscalls"
if [ -n "$KIRK_RUN_PATTERN" ]; then
    cp $LTP_DIR/runtest/syscalls $RUNTEST_BACKUP
    awk -v pattern="$KIRK_RUN_PATTERN" '$1 ~ pattern' \
        $RUNTEST_BACKUP > $LTP_DIR/runtest/syscalls
fi
if [ "$KIRK_VERBOSE" = "1" ]; then
    KIRK_ARGS="--verbose $KIRK_ARGS"
fi

CREATE_ENTRIES=1 $LTP_DIR/kirk --no-colors --tmp-dir $TEST_TMP_DIR \
    --json-report $JSON_REPORT $KIRK_ARGS > $LOG_FILE 2>&1
if [ $? -ne 0 ]; then
    RESULT=1
fi

cat $LOG_FILE
if ! grep -Eq "Failed:[[:space:]]+0" $LOG_FILE ||
    ! grep -Eq "Broken:[[:space:]]+0" $LOG_FILE ||
    ! grep -Eq "Warnings:[[:space:]]+0" $LOG_FILE; then
    RESULT=1
fi

exit $RESULT
