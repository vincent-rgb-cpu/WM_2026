# Makefile -- convenience targets for the WM 2026 pipeline.
# Usage:  make all | make data | make train | make predict | make simulate

RSCRIPT = Rscript

.PHONY: all setup data train predict simulate simulate-n clean

all: data train predict simulate

setup:
	$(RSCRIPT) scripts/00_setup.R

data:
	$(RSCRIPT) scripts/01_build_dataset.R

train:
	$(RSCRIPT) scripts/02_train_evaluate.R

predict:
	$(RSCRIPT) scripts/03_predict_tournament.R

simulate:
	$(RSCRIPT) scripts/04_simulate.R

# Run the full tournament sim with a custom N, e.g.  make simulate-n N=2000
simulate-n:
	$(RSCRIPT) scripts/04_simulate.R $(N)

# Remove generated artefacts (keeps cached raw downloads).
clean:
	rm -f data/processed/*.rds output/*.csv output/models/*.rds
