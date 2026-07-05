
python data/src/download_histroy.py
python src/features/build_features.py
python src/labels/create_regime_labels.py
python src/models/train_stage1_regime.py
#python src/live/predict_live_regime.py
python src/labels/create_trade_labels.py
python src/models/train_stage2_trade.py

