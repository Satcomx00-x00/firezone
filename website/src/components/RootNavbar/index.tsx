"use client";
import Image from "next/image";
import Link from "next/link";
import SidebarToggle from "./SidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";
import RequestAccessButton from "@/components/RequestAccessButton";
import { useEffect } from "react";
import { initFlowbite, Dropdown } from "flowbite";
import { HiChevronDown } from "react-icons/hi2";

export default function RootNavbar() {
  const p = usePathname() || "";
  let dropdown: any = null;

  useEffect(() => {
    if (!dropdown) {
      dropdown = new Dropdown(
        document.getElementById("product-dropdown-menu"),
        document.getElementById("product-dropdown-link")
      );
    }
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  const hideDropdown = () => {
    if (!dropdown) {
      dropdown = new Dropdown(
        document.getElementById("product-dropdown-menu"),
        document.getElementById("product-dropdown-link")
      );
    }

    dropdown.hide();
  };

  return (
    <header>
      <nav className="h-14 fixed top-0 left-0 right-0 bg-white border-b items-center flex border-neutral-200 z-50">
        <div className="w-full flex flex-wrap py-2 justify-between items-center">
          <div className="flex justify-start items-center">
            <SidebarToggle />
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-main.svg"
                className="md:hidden w-9 ml-2 flex"
                alt="Firezone Logo"
              />
            </Link>
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-text.svg"
                className="hidden md:flex w-32 sm:w-40 ml-2 mr-2 sm:mr-5"
                alt="Firezone Logo"
              />
            </Link>
            <span className="p-2"></span>
            <Link
              className={
                (p == "/" ? "text-neutral-900 underline" : "text-neutral-800") +
                " p-0 sm:p-1 mr-1 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/"
            >
              Home
            </Link>
            <span className="p-2"></span>
            <button
              id="product-dropdown-link"
              className={
                (p.startsWith("/product")
                  ? "text-neutral-900"
                  : "text-neutral-800") +
                " hover:text-neutral-900 flex items-center justify-between p-0 sm:p-1 mr-1"
              }
            >
              <span
                className={
                  "hover:underline font-medium " +
                  (p.startsWith("/product") ? "underline" : "")
                }
              >
                Product
              </span>
              <HiChevronDown className="w-3 h-3 mx-1" />
            </button>
            <div
              id="product-dropdown-menu"
              className="z-10 hidden bg-white divide-y divide-gray-100 rounded shadow-lg w-44"
            >
              <ul className="py-2" aria-labelledby="product-dropdown-link">
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/product/roadmap"
                    className={
                      (p == "/product/roadmap"
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Roadmap
                  </Link>
                </li>
                <li>
                  {/* TODO: use <Link> here, toggling dropdown */}
                  <Link
                    onClick={hideDropdown}
                    href="/product/early-access"
                    className={
                      (p == "/product/early-access"
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Early Access
                  </Link>
                </li>
                <li>
                  {/* TODO: use <Link> here, toggling dropdown */}
                  <Link
                    onClick={hideDropdown}
                    href="/product/newsletter"
                    className={
                      (p.startsWith("/product/newsletter")
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Newsletter
                  </Link>
                </li>
              </ul>
            </div>
            <Link
              className={
                (p.startsWith("/contact/sales")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-1 mr-1 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/contact/sales"
            >
              Contact
            </Link>
          </div>
          <div className="hidden md:flex items-center lg:order-2">
            <Link
              className={
                (p.startsWith("/docs")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-1 mr-1 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/docs"
            >
              Docs
            </Link>
            <Link
              href="https://github.com/firezone/firezone"
              className="p-2 mr-1"
              aria-label="GitHub Repository"
            >
              <Image
                alt="Github Repo stars"
                height={50}
                width={100}
                className=""
                src="https://img.shields.io/github/stars/firezone/firezone?label=Stars&amp;style=social"
              />
            </Link>
            <span className="mr-2">
              <RequestAccessButton />
            </span>
          </div>
        </div>
      </nav>
    </header>
  );
}
