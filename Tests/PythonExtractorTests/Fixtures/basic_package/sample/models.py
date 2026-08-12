class Model:
    def __init__(self, name):
        self.name = name

    def describe(self):
        return "model:" + self.name


def create_model(name):
    return Model(name)
