PYTHON ?= python2.7

INDIR  := input
OUTDIR := ../static/wizard

INPUT  := $(shell find ${INDIR}/ -type f -name '*.yaml')
OUTPUT := ${OUTDIR}/wizard.js

.PHONY: clean

${OUTPUT}: ${INPUT}
	${PYTHON} wizard.py ${INDIR} ${OUTPUT}

clean:
	-${RM} ${OUTPUT}
