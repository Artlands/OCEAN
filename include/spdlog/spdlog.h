#ifndef OCEAN_COMPAT_SPDLOG_H
#define OCEAN_COMPAT_SPDLOG_H

#include <cstdlib>
#include <format>
#include <iostream>
#include <mutex>
#include <string_view>
#include <utility>

#define SPDLOG_LEVEL_TRACE 0
#define SPDLOG_LEVEL_DEBUG 1
#define SPDLOG_LEVEL_INFO 2
#define SPDLOG_LEVEL_WARN 3
#define SPDLOG_LEVEL_ERROR 4
#define SPDLOG_LEVEL_CRITICAL 5
#define SPDLOG_LEVEL_OFF 6

#ifndef SPDLOG_ACTIVE_LEVEL
#define SPDLOG_ACTIVE_LEVEL SPDLOG_LEVEL_INFO
#endif

namespace spdlog {

namespace level {
enum level_enum {
    trace = SPDLOG_LEVEL_TRACE,
    debug = SPDLOG_LEVEL_DEBUG,
    info = SPDLOG_LEVEL_INFO,
    warn = SPDLOG_LEVEL_WARN,
    err = SPDLOG_LEVEL_ERROR,
    critical = SPDLOG_LEVEL_CRITICAL,
    off = SPDLOG_LEVEL_OFF,
};
}

namespace details {

inline const char* level_name(level::level_enum level) noexcept {
    switch (level) {
    case level::trace:
        return "trace";
    case level::debug:
        return "debug";
    case level::info:
        return "info";
    case level::warn:
        return "warn";
    case level::err:
        return "error";
    case level::critical:
        return "critical";
    case level::off:
    default:
        return "off";
    }
}

inline level::level_enum parse_level(std::string_view level_text) noexcept {
    if (level_text == "trace") {
        return level::trace;
    }
    if (level_text == "debug") {
        return level::debug;
    }
    if (level_text == "info") {
        return level::info;
    }
    if (level_text == "warn" || level_text == "warning") {
        return level::warn;
    }
    if (level_text == "error" || level_text == "err") {
        return level::err;
    }
    if (level_text == "critical") {
        return level::critical;
    }
    if (level_text == "off") {
        return level::off;
    }
    return level::info;
}

inline level::level_enum& runtime_level() noexcept {
    static level::level_enum current = [] {
        if (const char* env = std::getenv("SPDLOG_LEVEL")) {
            return parse_level(env);
        }
        return level::info;
    }();
    return current;
}

inline std::mutex& log_mutex() noexcept {
    static std::mutex mutex;
    return mutex;
}

inline bool enabled(level::level_enum level) noexcept {
    return level >= runtime_level() && runtime_level() != level::off;
}

inline std::ostream& stream_for(level::level_enum level) noexcept {
    return level >= level::warn ? std::cerr : std::cout;
}

inline void emit(level::level_enum level, std::string_view message) {
    if (!enabled(level)) {
        return;
    }
    std::lock_guard<std::mutex> guard(log_mutex());
    auto& os = stream_for(level);
    os << '[' << level_name(level) << "] " << message;
    if (message.empty() || message.back() != '\n') {
        os << '\n';
    }
    os.flush();
}

inline void log(level::level_enum level, std::string_view message) {
    emit(level, message);
}

template <typename... Args>
inline void log(level::level_enum level, std::format_string<Args...> fmt, Args&&... args) {
    emit(level, std::format(fmt, std::forward<Args>(args)...));
}

} // namespace details

inline void set_level(level::level_enum level) noexcept {
    details::runtime_level() = level;
}


namespace cfg {
inline void load_env_levels() noexcept {
    if (const char* env = std::getenv("SPDLOG_LEVEL")) {
        details::runtime_level() = details::parse_level(env);
    }
}
} // namespace cfg

} // namespace spdlog

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_TRACE
#define SPDLOG_TRACE(...) ::spdlog::details::log(::spdlog::level::trace, __VA_ARGS__)
#else
#define SPDLOG_TRACE(...) ((void)0)
#endif

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_DEBUG
#define SPDLOG_DEBUG(...) ::spdlog::details::log(::spdlog::level::debug, __VA_ARGS__)
#else
#define SPDLOG_DEBUG(...) ((void)0)
#endif

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_INFO
#define SPDLOG_INFO(...) ::spdlog::details::log(::spdlog::level::info, __VA_ARGS__)
#else
#define SPDLOG_INFO(...) ((void)0)
#endif

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_WARN
#define SPDLOG_WARN(...) ::spdlog::details::log(::spdlog::level::warn, __VA_ARGS__)
#else
#define SPDLOG_WARN(...) ((void)0)
#endif

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_ERROR
#define SPDLOG_ERROR(...) ::spdlog::details::log(::spdlog::level::err, __VA_ARGS__)
#else
#define SPDLOG_ERROR(...) ((void)0)
#endif

#if SPDLOG_ACTIVE_LEVEL <= SPDLOG_LEVEL_CRITICAL
#define SPDLOG_CRITICAL(...) ::spdlog::details::log(::spdlog::level::critical, __VA_ARGS__)
#else
#define SPDLOG_CRITICAL(...) ((void)0)
#endif

#endif
