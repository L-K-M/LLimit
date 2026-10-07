import importlib.util
from pathlib import Path
import unittest
import re

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("palette_validation", ROOT / "scripts/validate-palettes.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class PaletteValidationTests(unittest.TestCase):
    def test_actual_palettes_pass_normal_and_cvd_gates(self):
        for name, colors in validator.read_palettes(ROOT).items():
            with self.subTest(palette=name):
                distances, chroma, graphite, blue = validator.measurements(colors)
                for vision, (base, twelve) in distances.items():
                    self.assertGreaterEqual(base, 12, vision)
                    self.assertGreaterEqual(twelve, 8, vision)
                self.assertGreaterEqual(chroma, .10)
                self.assertGreaterEqual(graphite, 3)
                self.assertGreaterEqual(blue, 1)

    def test_protanopia_canary_catches_a_confusable_pair(self):
        red = validator.hex_to_rgb("#FF0000")
        green = validator.hex_to_rgb("#006A00")
        normal = validator.delta_e(validator.lab_of_rgb(red), validator.lab_of_rgb(green))
        simulated = validator.delta_e(validator.simulate_cvd(red, "protan"),
                                      validator.simulate_cvd(green, "protan"))
        self.assertGreater(normal, 80)
        self.assertLess(simulated, 12)

    def test_wcag_contrast_reference(self):
        self.assertAlmostEqual(validator.contrast((0, 0, 0), (1, 1, 1)), 21)

    def test_oklch_chroma_reference(self):
        self.assertAlmostEqual(validator.chroma((1, 0, 0)), .2576833, places=6)
        self.assertAlmostEqual(validator.chroma((.5, .5, .5)), 0, places=6)

    def test_dashboard_text_contrast_in_both_appearances(self):
        source = (ROOT / "Packages/QuotaCore/Sources/QuotaCore/DashboardAppearance.swift").read_text()
        fields = re.findall(r'var (\w+): String \{ self == \.light \? "(#[0-9A-F]+)" : "(#[0-9A-F]+)"', source)
        for appearance in (0, 1):
            colors = {name: validator.hex_to_rgb((light, dark)[appearance]) for name, light, dark in fields}
            for surface in ("backgroundTopHex", "backgroundBottomHex", "cardHex", "cardHoverHex"):
                for text in ("primaryTextHex", "secondaryTextHex", "tertiaryTextHex", "warningHex", "dangerHex", "successHex"):
                    with self.subTest(appearance=appearance, surface=surface, text=text):
                        self.assertGreaterEqual(validator.contrast(colors[text], colors[surface]), 4.5)
        self.assertGreaterEqual(validator.contrast(validator.hex_to_rgb(validator.GRAPHITE),
                                                   validator.hex_to_rgb(validator.WIDGET_BLUE)), 3)


if __name__ == "__main__":
    unittest.main()
