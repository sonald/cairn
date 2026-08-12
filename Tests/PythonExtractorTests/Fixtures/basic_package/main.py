from sample.service import Service as Svc


def main():
    service = Svc()
    return service.refresh()
