// Command text-template renders one Go text/template with a JSON document as
// its data and writes the result to stdout.
//
//	text-template <template> <data.json>
//
// The template can read only that document: no functions beyond Go's
// builtins are defined, so a gomplate-style env, file, or http call fails at
// parse time. A missing key fails execution, whether read through a field or
// through index. A JSON null stays false in a condition, but printing it
// fails, directly, inside a printed map or list, or through print, printf,
// println, html, js, or urlquery. A range over a null fails too. Integers
// print as integers. Nothing reaches stdout unless the whole render succeeds.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"text/template"
)

// null stands for a JSON null. A nil pointer is false in a condition, as the
// null was, and an action that prints it writes nullMark, which the output
// check finds: Go would print a bare null as "<no value>" or "<nil>", which
// can also be literal prose.
type null struct{}

var nullMark string

func (*null) String() string { return nullMark }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "text-template:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 2 {
		return errors.New("usage: text-template <template> <data.json>")
	}
	templatePath, dataPath := args[0], args[1]

	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	nullMark = "textTemplateNull" + hex.EncodeToString(nonce)

	source, err := os.ReadFile(templatePath)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(dataPath)
	if err != nil {
		return err
	}
	// Maps, not structs: missingkey applies only to map lookups. Numbers stay
	// json.Number until convert, so an integer does not print as 1e+06.
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var document map[string]any
	if err := decoder.Decode(&document); err != nil {
		return fmt.Errorf("%s: %w", dataPath, err)
	}
	data := convert(document)

	tmpl, err := template.New(filepath.Base(templatePath)).
		Option("missingkey=error").
		Funcs(template.FuncMap{
			"index":    strictIndex,
			"print":    rejectNull("print", fmt.Sprint),
			"println":  rejectNull("println", fmt.Sprintln),
			"html":     rejectNull("html", template.HTMLEscaper),
			"js":       rejectNull("js", template.JSEscaper),
			"urlquery": rejectNull("urlquery", template.URLQueryEscaper),
			"printf": func(format string, args ...any) (string, error) {
				if err := checkArgs("printf", args); err != nil {
					return "", err
				}
				return fmt.Sprintf(format, args...), nil
			},
		}).
		Parse(string(source))
	if err != nil {
		return err
	}
	var out bytes.Buffer
	if err := tmpl.Execute(&out, data); err != nil {
		return err
	}
	if bytes.Contains(out.Bytes(), []byte(nullMark)) {
		return fmt.Errorf("%s: output prints a null value", templatePath)
	}
	_, err = os.Stdout.Write(out.Bytes())
	return err
}

// convert replaces each JSON null with a nil *null and each number with an
// int64, or a float64 when it is not an integer.
func convert(value any) any {
	switch value := value.(type) {
	case nil:
		return (*null)(nil)
	case json.Number:
		if integer, err := value.Int64(); err == nil {
			return integer
		}
		float, _ := value.Float64()
		return float
	case map[string]any:
		for key, element := range value {
			value[key] = convert(element)
		}
		return value
	case []any:
		for i, element := range value {
			value[i] = convert(element)
		}
		return value
	default:
		return value
	}
}

// rejectNull wraps a formatting builtin so that a null argument fails instead
// of reaching the output transformed, for example hex-encoded by printf "%x",
// where the output check could not find it.
func rejectNull(name string, format func(...any) string) func(...any) (string, error) {
	return func(args ...any) (string, error) {
		if err := checkArgs(name, args); err != nil {
			return "", err
		}
		return format(args...), nil
	}
}

func checkArgs(name string, args []any) error {
	for i, arg := range args {
		if holdsNull(arg) {
			return fmt.Errorf("%s: argument %d is null", name, i+1)
		}
	}
	return nil
}

func holdsNull(value any) bool {
	switch value := value.(type) {
	case *null:
		return true
	case map[string]any:
		for _, element := range value {
			if holdsNull(element) {
				return true
			}
		}
	case []any:
		for _, element := range value {
			if holdsNull(element) {
				return true
			}
		}
	}
	return false
}

// strictIndex replaces the builtin index, which returns the zero value for a
// missing map key whatever missingkey says, so a missing fact read in an `if`
// would render the false branch instead of failing.
func strictIndex(item any, keys ...any) (any, error) {
	for _, key := range keys {
		switch collection := item.(type) {
		case map[string]any:
			name, ok := key.(string)
			if !ok {
				return nil, fmt.Errorf("index: map key %v is not a string", key)
			}
			value, ok := collection[name]
			if !ok {
				return nil, fmt.Errorf("index: map has no entry for key %q", name)
			}
			item = value
		case []any:
			position, ok := key.(int)
			if !ok || position < 0 || position >= len(collection) {
				return nil, fmt.Errorf("index: %v is out of range for a list of %d", key, len(collection))
			}
			item = collection[position]
		default:
			return nil, fmt.Errorf("index: cannot index %T", item)
		}
	}
	return item, nil
}
