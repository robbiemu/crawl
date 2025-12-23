#pragma once

#include <string>

enum class resonance_forge_target
{
    weapon,
    ranged,
    armour,
    shield,
    offhand,
    thrown,
};

bool resonance_forge_target_from_string(const std::string &name,
                                        resonance_forge_target &target);

std::string resonance_forge_target_name(resonance_forge_target target);

bool resonance_forge_apply(resonance_forge_target target, std::string &message,
                           bool &spawn_wave);

inline bool resonance_forge_apply(resonance_forge_target target)
{
    std::string msg;
    bool spawn_wave = true;
    const bool ok = resonance_forge_apply(target, msg, spawn_wave);
    return ok;
}

bool resonance_forge_show_prompt(resonance_forge_target target);
