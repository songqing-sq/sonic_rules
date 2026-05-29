import configparser, os, sys, tarfile

def wants_targets(unit_path):
    cp = configparser.ConfigParser(strict=False, delimiters=("=",))
    cp.optionxform = str
    cp.read(unit_path)
    out = []
    if cp.has_section("Install"):
        for key, want_dir in (("WantedBy", "wants"), ("RequiredBy", "requires")):
            if cp.has_option("Install", key):
                for tgt in cp.get("Install", key).split():
                    out.append((tgt, want_dir))
    return out

def main():
    out_tar = sys.argv[1]
    unit_dir = "/lib/systemd/system"
    enable_units = sys.argv[2].split(",") if sys.argv[2] else []
    mask_units = sys.argv[3].split(",") if len(sys.argv) > 3 and sys.argv[3] else []
    units_root = sys.argv[4]
    with tarfile.open(out_tar, "w") as tf:
        for unit in enable_units:
            if not unit: continue
            for tgt, want_dir in wants_targets(os.path.join(units_root, unit)):
                link = "./etc/systemd/system/%s.%s/%s" % (tgt, want_dir, unit)
                ti = tarfile.TarInfo(link); ti.type = tarfile.SYMTYPE
                ti.linkname = "%s/%s" % (unit_dir, unit)
                tf.addfile(ti)
        for unit in mask_units:
            if not unit: continue
            link = "./etc/systemd/system/%s" % unit
            ti = tarfile.TarInfo(link); ti.type = tarfile.SYMTYPE
            ti.linkname = "/dev/null"
            tf.addfile(ti)

if __name__ == "__main__":
    main()
