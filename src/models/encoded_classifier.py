import numpy as np


class EncodedClassifier:
    def __init__(self, model, class_to_label: dict[int, int]):
        self.model = model
        self.class_to_label = class_to_label
        self.classes_ = np.array(
            [self.class_to_label[int(class_id)] for class_id in self.model.classes_]
        )

    def predict(self, features):
        encoded_predictions = self.model.predict(features)
        return np.array(
            [self.class_to_label[int(class_id)] for class_id in encoded_predictions]
        )

    def predict_proba(self, features):
        return self.model.predict_proba(features)
