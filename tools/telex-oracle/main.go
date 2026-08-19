package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	bamboo "github.com/BambooEngine/bamboo-core"
)

// Usage: echo "std KEYS" per line on stdin; std=1 -> old-style (òa), std=0 -> new-style (oà)
func main() {
	imDef := bamboo.GetInputMethodDefinitions()
	im := bamboo.ParseInputMethod(imDef, "Telex")
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		flags := bamboo.EfreeToneMarking | bamboo.EautoCorrectEnabled
		if parts[0] == "1" {
			flags |= bamboo.EstdToneStyle // std/old style
		}
		keys := ""
		if len(parts) > 1 {
			keys = parts[1]
		}
		// bamboo processes a word buffer; strip a trailing '.' word-break marker.
		keys = strings.TrimSuffix(keys, ".")
		ng := bamboo.NewEngine(im, flags)
		ng.ProcessString(keys, bamboo.VietnameseMode)
		fmt.Println(ng.GetProcessedString(bamboo.VietnameseMode))
	}
}
