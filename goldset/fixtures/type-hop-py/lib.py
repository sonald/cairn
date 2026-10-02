class Repository:
    pass


def f(repo, count):
    # type: (Optional["Repository"], int) -> None
    return repo, count


def g(repo: "Repository", count: int):
    return repo, count


class Holder:
    def me(self):
        return self
