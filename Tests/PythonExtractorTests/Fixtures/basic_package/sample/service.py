from .models import Model as M
from sample.models import create_model as make


class Service:
    def __init__(self):
        self.local = []

    def refresh(self):
        model = make("svc")
        self.local.append(model)
        return model
