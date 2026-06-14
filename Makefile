# Makefile -- convenience targets for the WM 2026 pipeline.
# Usage:  make all   |   make data   |   make train   |   make predict

RSCRIPT = Rscript

.PHONY: all setup data train predict clean

all: data train predict

setup:
	$(RSCRIPT) scripts/00_setup.R

data:
	$(RSCRIPT) scripts/01_build_dataset.R

train:
	$(RSCRIPT) scripts/02_train_evaluate.R

predict:
	$(RSCRIPT) scripts/03_predict_tournament.R

# Remove generated artefacts (keeps cached raw downloads).
clean:
	rm -f data/processed/*.rds output/*.csv output/models/*.rds
