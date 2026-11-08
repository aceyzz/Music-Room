package config

import (
	"os"
	"strconv"
)

// We create the interface that constraint the differents types
// of environment variables.
type EnvType interface {
	~string | ~int | ~bool
}

func Getenv[T EnvType](keytype string, fallback T) T {
	envString := os.Getenv(keytype)

	if envString == "" {
		return fallback
	}

	var err error
	var parsed any

	switch any(fallback).(type) {
	case int:
		parsed, err = _getenvInt(envString)
	case bool:
		parsed, err = _getenvBool(envString)
	case string:
		parsed, err = _getenvString(envString)
	default:
		return fallback
	}

	if err != nil {
		return fallback
	}

	return parsed.(T)
}

func _getenvString(envStr string) (string, error) {
	return envStr, nil
}

func _getenvInt(envStr string) (int, error) {
	return strconv.Atoi(envStr)
}

func _getenvBool(envStr string) (bool, error) {
	return strconv.ParseBool(envStr)
}
