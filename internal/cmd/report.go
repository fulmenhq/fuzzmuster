package cmd

import (
	"fmt"
	"io"
)

// report writes a diagnostic report and keeps the first write error, so a
// report that could not be written fails its command.
type report struct {
	w   io.Writer
	err error
}

func (r *report) printf(format string, args ...any) {
	if r.err == nil {
		_, r.err = fmt.Fprintf(r.w, format, args...)
	}
}

func (r *report) println(text string) { r.printf("%s\n", text) }

// done returns the write error, if any, or the command's own error.
func (r *report) done(err error) error {
	if r.err != nil {
		return fmt.Errorf("cannot write report: %w", r.err)
	}
	return err
}
