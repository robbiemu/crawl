#include "AppHdr.h"

#include "resonance-forge.h"

#include "artefact.h"
#include "enum.h"
#include "invent.h"
#include "player-equip.h"
#include "item-name.h"
#include "item-prop.h"
#include "item-use.h"
#include "items.h"
#include "cio.h"
#include "mpr.h"
#include "misc.h"
#include "player.h"
#include "quiver.h"
#include "random.h"
#include "scroller.h"
#include "stringutil.h"
#include "format.h"
#include "ui.h"
#include "notes.h"

using std::string;
using namespace ui;

namespace
{

bool _eligible_item(const item_def &item)
{
    return in_inventory(item) || item_is_equipped(item);
}

bool _item_is_artefact(const item_def &item)
{
    return is_artefact(item);
}

special_missile_type _random_thrown_brand(const item_def &ammo)
{
    switch (ammo.sub_type)
    {
    case MI_JAVELIN:
        return random_choose_weighted(
            45, SPMSL_SILVER,
            35, SPMSL_DISPERSAL,
            20, SPMSL_CHAOS);

    case MI_LARGE_ROCK:
    case MI_STONE:
        return random_choose_weighted(
            60, SPMSL_DISPERSAL,
            40, SPMSL_CHAOS);

    case MI_DART:
        return random_choose_weighted(
            50, SPMSL_DISJUNCTION,
            35, SPMSL_DISPERSAL,
            15, SPMSL_CHAOS);

    case MI_THROWING_NET:
        return SPMSL_DISPERSAL;

    case MI_SLING_BULLET:
    case MI_SLUG:
    case MI_BOOMERANG:
    default:
        return random_choose_weighted(
            65, SPMSL_DISPERSAL,
            35, SPMSL_CHAOS);
    }
}

void _announce_success(const string &old_name, const string &new_name)
{
    string message;
    if (old_name == new_name)
        message = make_stringf("You infuse %s with resonant harmonics!", new_name.c_str());
    else
        message = make_stringf("You forge %s into %s!", old_name.c_str(), new_name.c_str());

    mprf(MSGCH_INTRINSIC_GAIN, "%s", message.c_str());
    take_note(Note(NOTE_MESSAGE, 0, 0, "", message));
}

bool _rebrand_melee(item_def &item)
{
    rebrand_weapon(item);
    return true;
}

bool _apply_armour_brand(item_def &item)
{
    const armour_type type = static_cast<armour_type>(item.sub_type);
    special_armour_type new_brand = SPARM_NORMAL;
    for (int i = 0; i < 10 && new_brand == SPARM_NORMAL; ++i)
        new_brand = choose_armour_ego(type);
    if (new_brand == SPARM_NORMAL)
        new_brand = random_choose_weighted(1, SPARM_PONDEROUSNESS,
                                           1, SPARM_RESISTANCE,
                                           1, SPARM_REFLECTION,
                                           1, SPARM_WILLPOWER,
                                           1, SPARM_RAMPAGING);
    set_item_ego_type(item, OBJ_ARMOUR, new_brand);
    return true;
}

bool _apply_shield_brand(item_def &item)
{
    return _apply_armour_brand(item);
}

bool _apply_thrown_brand(item_def &item)
{
    const special_missile_type brand = _random_thrown_brand(item);
    set_item_ego_type(item, OBJ_MISSILES, brand);
    return true;
}

vector<item_def*> _gather_armour_targets()
{
    const equipment_slot armour_slots[] = {
        SLOT_BODY_ARMOUR,
        SLOT_CLOAK,
        SLOT_HELMET,
        SLOT_GLOVES,
        SLOT_BOOTS,
        SLOT_BARDING,
    };

    vector<item_def*> items;
    for (const equipment_slot slot : armour_slots)
    {
        if (item_def *it = you.equipment.get_first_slot_item(slot, true))
        {
            items.push_back(it);
        }
    }
    return items;
}

item_def *_get_wielded_weapon()
{
    return you.weapon();
}

item_def *_get_ranged_weapon()
{
    item_def *wpn = you.weapon();
    if (!wpn || !is_range_weapon(*wpn))
        return nullptr;
    return wpn;
}

item_def *_get_shield()
{
    return you.shield();
}

item_def *_get_offhand_weapon()
{
    return you.offhand_weapon();
}

item_def *_get_quivered_item()
{
    auto action = you.quiver_action.get();
    if (!action)
        return nullptr;
    const int slot = action->get_item();
    if (slot == -1)
        return nullptr;
    item_def &item = you.inv[slot];
    if (!_eligible_item(item))
        return nullptr;
    if (item.base_type != OBJ_MISSILES)
        return nullptr;
    return &item;
}

string _item_desc(const item_def &item)
{
    return item.name(in_inventory(item) ? DESC_YOUR : DESC_THE);
}

bool _handle_resonance_resistance(const item_def &item, string &message,
                                  bool &spawn_wave)
{
    message = make_stringf("The forge's resonance skitters off %s; it resists change.",
                           _item_desc(item).c_str());
    spawn_wave = false;
    return true;
}

string _forge_focus_name(resonance_forge_target target)
{
    switch (target)
    {
    case resonance_forge_target::weapon:  return "weapon";
    case resonance_forge_target::ranged:  return "ranged weapon";
    case resonance_forge_target::armour:  return "armour";
    case resonance_forge_target::shield:  return "shield";
    case resonance_forge_target::offhand: return "off-hand weapon";
    case resonance_forge_target::thrown:  return "throwing ammunition";
    }
    return "item";
}

string _forge_usage_hint(resonance_forge_target target)
{
    switch (target)
    {
    case resonance_forge_target::weapon:
        return "Wield the melee weapon you wish to reshape before invoking the forge.";
    case resonance_forge_target::ranged:
        return "Wield the bow, crossbow, or launcher you wish to reshape.";
    case resonance_forge_target::armour:
        return "Wear the piece of armour you wish to retune.";
    case resonance_forge_target::shield:
        return "Equip the shield you wish to reshape in your off hand.";
    case resonance_forge_target::offhand:
        return "Equip the auxiliary or off-hand weapon you wish to retune.";
    case resonance_forge_target::thrown:
        return "Quiver the ammunition stack you wish to retune.";
    }
    return "Ensure the item you wish to reshape is equipped.";
}

} // namespace

bool resonance_forge_show_prompt(resonance_forge_target target)
{
    auto root = make_shared<Box>(Box::VERT);
    root->set_cross_alignment(Widget::STRETCH);

    const string focus = _forge_focus_name(target);
    auto title_box = make_shared<Box>(Widget::HORZ);
    title_box->set_main_alignment(Widget::CENTER);
    title_box->set_cross_alignment(Widget::CENTER);
    auto title = make_shared<Text>(formatted_string::parse_string(
        make_stringf("<lightcyan>Resonance Forge — %s focus</lightcyan>",
                     focus.c_str())));
    title_box->add_child(std::move(title));
    root->add_child(std::move(title_box));

    string desc_body =
        "Channeling the forge retunes that equipped item, but each use summons additional guardians.\n"
        "Repeated use risks rupturing the forge entirely.\n";
    desc_body += _forge_usage_hint(target);
    desc_body += "\n\nPress Enter to invoke the forge.";

    auto desc_scroller = make_shared<Scroller>();
    auto desc_text = make_shared<Text>(formatted_string::parse_string(desc_body));
    desc_text->set_wrap_text(true);
    desc_scroller->set_child(desc_text);
    desc_scroller->set_margin_for_crt(1, 0);
    desc_scroller->set_margin_for_sdl(20, 0);
    root->add_child(desc_scroller);

    auto command_box = make_shared<Box>(Widget::HORZ);
    command_box->set_main_alignment(Widget::CENTER);
    command_box->set_cross_alignment(Widget::CENTER);
    auto command_text = make_shared<Text>(formatted_string::parse_string(
        "[<w>Enter</w>]: Invoke the forge."));
    command_text->set_margin_for_crt(1, 0, 0, 0);
    command_text->set_margin_for_sdl(20, 0, 0, 0);
    command_box->add_child(std::move(command_text));
    root->add_child(std::move(command_box));

    auto popup = make_shared<ui::Popup>(root);
    bool confirmed = false;
    bool done = false;
    popup->on_keydown_event([&](const KeyEvent &ev) {
        const int key = ev.key();
        if (key == CK_ENTER || key == '\n')
        {
            confirmed = true;
            done = true;
            return true;
        }
        if (key == CK_ESCAPE)
        {
            confirmed = false;
            done = true;
            return true;
        }
        return false;
    });

    ui::run_layout(popup, done);
    return confirmed;
}

bool resonance_forge_target_from_string(const string &name,
                                        resonance_forge_target &target)
{
    if (name == "weapon")
    {
        target = resonance_forge_target::weapon;
        return true;
    }
    if (name == "ranged")
    {
        target = resonance_forge_target::ranged;
        return true;
    }
    if (name == "armour")
    {
        target = resonance_forge_target::armour;
        return true;
    }
    if (name == "shield")
    {
        target = resonance_forge_target::shield;
        return true;
    }
    if (name == "offhand")
    {
        target = resonance_forge_target::offhand;
        return true;
    }
    if (name == "thrown")
    {
        target = resonance_forge_target::thrown;
        return true;
    }
    return false;
}

string resonance_forge_target_name(resonance_forge_target target)
{
    switch (target)
    {
    case resonance_forge_target::weapon:  return "weapon";
    case resonance_forge_target::ranged:  return "ranged weapon";
    case resonance_forge_target::armour:  return "armour";
    case resonance_forge_target::shield:  return "shield";
    case resonance_forge_target::offhand: return "off-hand weapon";
    case resonance_forge_target::thrown:  return "thrown ammunition";
    }
    return "item";
}

bool resonance_forge_apply(resonance_forge_target target, string &message,
                           bool &spawn_wave)
{
    spawn_wave = true;
    message.clear();

    switch (target)
    {
    case resonance_forge_target::weapon:
    {
        item_def *weapon = _get_wielded_weapon();
        if (!weapon || is_range_weapon(*weapon))
        {
            message = "You have no suitable melee weapon wielded.";
            spawn_wave = false;
            return false;
        }
        if (_item_is_artefact(*weapon))
            return _handle_resonance_resistance(*weapon, message, spawn_wave);
        const string old_name = _item_desc(*weapon);
        _rebrand_melee(*weapon);
        const string new_name = _item_desc(*weapon);
        _announce_success(old_name, new_name);
        you.gear_change = true;
        return true;
    }
    case resonance_forge_target::ranged:
    {
        item_def *weapon = _get_ranged_weapon();
        if (!weapon)
        {
            message = "You must wield a launcher to attune it.";
            spawn_wave = false;
            return false;
        }
        if (_item_is_artefact(*weapon))
            return _handle_resonance_resistance(*weapon, message, spawn_wave);
        const string old_name = _item_desc(*weapon);
        _rebrand_melee(*weapon);
        const string new_name = _item_desc(*weapon);
        _announce_success(old_name, new_name);
        you.gear_change = true;
        return true;
    }
    case resonance_forge_target::armour:
    {
        auto armour = _gather_armour_targets();
        if (armour.empty())
        {
            message = "You are not wearing any reforgable armour.";
            spawn_wave = false;
            return false;
        }
        item_def *choice = armour[random2(armour.size())];
        if (_item_is_artefact(*choice))
            return _handle_resonance_resistance(*choice, message, spawn_wave);
        const string old_name = _item_desc(*choice);
        _apply_armour_brand(*choice);
        const string new_name = _item_desc(*choice);
        _announce_success(old_name, new_name);
        you.redraw_armour_class = true;
        you.redraw_evasion = true;
        you.gear_change = true;
        return true;
    }
    case resonance_forge_target::shield:
    {
        item_def *shield = _get_shield();
        if (!shield)
        {
            message = "You are not wielding a reforgable shield.";
            spawn_wave = false;
            return false;
        }
        if (_item_is_artefact(*shield))
            return _handle_resonance_resistance(*shield, message, spawn_wave);
        const string old_name = _item_desc(*shield);
        _apply_shield_brand(*shield);
        const string new_name = _item_desc(*shield);
        _announce_success(old_name, new_name);
        you.redraw_armour_class = true;
        you.redraw_evasion = true;
        you.gear_change = true;
        return true;
    }
    case resonance_forge_target::offhand:
    {
        item_def *offhand = _get_offhand_weapon();
        if (!offhand)
        {
            message = "You have no reforgable off-hand weapon.";
            spawn_wave = false;
            return false;
        }
        if (_item_is_artefact(*offhand))
            return _handle_resonance_resistance(*offhand, message, spawn_wave);
        const string old_name = _item_desc(*offhand);
        _rebrand_melee(*offhand);
        const string new_name = _item_desc(*offhand);
        _announce_success(old_name, new_name);
        you.gear_change = true;
        return true;
    }
    case resonance_forge_target::thrown:
    {
        item_def *ammo = _get_quivered_item();
        if (!ammo)
        {
            message = "You must quiver ammunition to reforge it.";
            spawn_wave = false;
            return false;
        }
        if (_item_is_artefact(*ammo))
            return _handle_resonance_resistance(*ammo, message, spawn_wave);
        const string old_name = _item_desc(*ammo);
        _apply_thrown_brand(*ammo);
        const string new_name = _item_desc(*ammo);
        _announce_success(old_name, new_name);
        quiver::set_needs_redraw();
        you.gear_change = true;
        return true;
    }
    }

    spawn_wave = false;
    message = "The forge cannot function.";
    return false;
}
